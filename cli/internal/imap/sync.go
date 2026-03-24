package imap

import (
	"bytes"
	"fmt"
	"io"
	"log/slog"
	"net/mail"
	"os"
	"sort"
	"strings"
	"time"

	goimap "github.com/emersion/go-imap"

	"github.com/durian-dev/durian/cli/internal/config"
	durianmail "github.com/durian-dev/durian/cli/internal/mail"
	"github.com/durian-dev/durian/cli/internal/store"
)

// SyncMode defines the sync direction
type SyncMode int

const (
	// SyncBidirectional syncs both directions (default)
	SyncBidirectional SyncMode = iota
	// SyncDownloadOnly only downloads from server
	SyncDownloadOnly
	// SyncUploadOnly only uploads local changes to server
	SyncUploadOnly
)

// FolderTagMapping defines which tags to add/remove when syncing a folder
// This is used for deduplication: when a mail already exists locally,
// we update tags instead of downloading again
type FolderTagMapping struct {
	AddTags    []string // Tags to add (e.g., "trash" for Trash folder)
	RemoveTags []string // Tags to remove (e.g., "inbox" when mail moved to Trash)
}

// specialUseFolderTags maps IMAP SPECIAL-USE attributes to tag operations
// These are standardized by RFC 6154
var specialUseFolderTags = map[string]FolderTagMapping{
	"\\Inbox":   {AddTags: []string{"inbox"}, RemoveTags: []string{}},
	"\\Sent":    {AddTags: []string{"sent"}, RemoveTags: []string{}},
	"\\Drafts":  {AddTags: []string{"draft"}, RemoveTags: []string{}},
	"\\Trash":   {AddTags: []string{"trash"}, RemoveTags: []string{"inbox"}},
	"\\Junk":    {AddTags: []string{"spam"}, RemoveTags: []string{"inbox"}},
	"\\Archive": {AddTags: []string{"archive"}, RemoveTags: []string{"inbox"}},
}

// SyncOptions configures the sync behavior
type SyncOptions struct {
	DryRun           bool
	Quiet            bool
	NoFlags          bool                // Skip flag synchronization
	Mode             SyncMode            // Sync direction
	Mailboxes        []string            // Specific mailboxes to sync (empty = all)
	Store            *store.DB           // SQLite store (required)
	FilterRules      []config.RuleConfig // User-defined filter rules applied at insert time
	BackfillHeaders  bool                // Fetch and store headers for existing messages
}

// SyncResult contains the results of a sync operation
type SyncResult struct {
	Account           string
	Mailboxes         []MailboxResult
	Duration          time.Duration
	TotalNew          int
	TotalSkipped      int
	TotalDeleted      int // Messages deleted locally (removed from server)
	TotalDeduplicated int // Messages that already existed locally (tags updated)
	FlagsUploaded     int // Flags uploaded to server
	FlagsDownload     int // Flags downloaded from server
	TotalMoved        int // Messages moved between IMAP folders
	NewMessageIDs     []string // Message-IDs of newly downloaded messages
	Error             error
}

// MailboxResult contains the results for a single mailbox
type MailboxResult struct {
	Name             string
	TotalMsgs        uint32
	NewMsgs          int
	SkippedMsgs      int
	DeletedMsgs      int // Messages deleted locally (removed from server)
	DeduplicatedMsgs int // Messages that already existed locally (tags updated)
	FlagsUploaded    int
	FlagsDownload    int
	MovedMsgs        int // Messages moved between IMAP folders
	NewMessageIDs    []string // Message-IDs of newly downloaded messages
	Error            error
}

// Syncer handles IMAP synchronization for an account
type Syncer struct {
	client          *Client
	state           *State
	stateMgr        *StateManager
	stateLock       *os.File             // File lock held during sync
	account         *config.AccountConfig
	options         *SyncOptions
	output          io.Writer
	trashMailbox    string                // Cached trash mailbox name for delete operations
	archiveMailbox  string                // Cached archive mailbox name for archive operations
	serverMailboxes []*goimap.MailboxInfo // Cached mailbox list for exclusion tags
	ownsClient      bool                  // true = syncer manages connection lifecycle
	store           *store.DB            // SQLite store for messages and tags
	parser          *durianmail.Parser   // Email parser for store writes
}

// NewSyncer creates a new syncer for an account
func NewSyncer(account *config.AccountConfig, options *SyncOptions) *Syncer {
	if options == nil {
		options = &SyncOptions{}
	}

	output := io.Writer(os.Stderr)
	if options.Quiet {
		output = io.Discard
	}

	return &Syncer{
		client:     NewClient(account),
		stateMgr:   NewStateManager(),
		account:    account,
		options:    options,
		output:     output,
		ownsClient: true,
		store:      options.Store,
		parser:     durianmail.NewParser(),
	}
}

// NewSyncerWithClient creates a syncer that reuses an existing IMAP connection.
// The caller owns the connection lifecycle (connect, auth, close).
func NewSyncerWithClient(account *config.AccountConfig, client *Client, options *SyncOptions) *Syncer {
	if options == nil {
		options = &SyncOptions{}
	}

	output := io.Writer(os.Stderr)
	if options.Quiet {
		output = io.Discard
	}

	return &Syncer{
		client:     client,
		stateMgr:   NewStateManager(),
		account:    account,
		options:    options,
		output:     output,
		ownsClient: false,
		store:      options.Store,
		parser:     durianmail.NewParser(),
	}
}

// Sync performs a full sync of the account
func (s *Syncer) Sync() (*SyncResult, error) {
	start := time.Now()
	result := &SyncResult{
		Account: s.account.Email,
	}

	// Load state (acquires file lock to prevent concurrent syncs)
	var err error
	s.state, s.stateLock, err = s.stateMgr.Load(s.account.Email)
	if err != nil {
		return nil, fmt.Errorf("failed to load state: %w", err)
	}
	defer releaseLock(s.stateLock)

	// Connect and authenticate (skip if caller owns the connection)
	if s.ownsClient {
		if err := s.client.Connect(); err != nil {
			return nil, err
		}
		defer s.client.Close()

		if err := s.client.Authenticate(); err != nil {
			return nil, err
		}
	}

	// Get mailboxes to sync
	mailboxes, err := s.getMailboxesToSync()
	if err != nil {
		return nil, err
	}

	// Cache server mailbox list for exclusion tag logic
	s.serverMailboxes, err = s.client.ListMailboxes()
	if err != nil {
		slog.Debug("Failed to cache server mailbox list", "module", "SYNC", "err", err)
	}

	// Sync each mailbox with automatic reconnection on failure
	for _, mbox := range mailboxes {
		mboxResult := s.syncMailbox(mbox)

		// Check if error is connection-related and try to reconnect
		if mboxResult.Error != nil && isConnectionError(mboxResult.Error) {
			if !s.ownsClient {
				// Caller owns the connection — don't reconnect (would open a
				// new socket that aggressive servers like M365 reject). Abort
				// early and let the caller's IDLE loop catch up next cycle.
				slog.Debug("Connection lost, aborting (caller-owned connection)", "module", "SYNC", "mailbox", mbox)
				result.Mailboxes = append(result.Mailboxes, mboxResult)
				result.Error = mboxResult.Error
				break
			}

			slog.Debug("Connection lost, attempting reconnect", "module", "SYNC", "mailbox", mbox)
			fmt.Fprintf(s.output, "  ⚠ Connection lost, reconnecting...\n")

			if err := s.client.Reconnect(); err != nil {
				slog.Debug("Reconnect failed", "module", "SYNC", "err", err)
				result.Mailboxes = append(result.Mailboxes, mboxResult)
				result.Error = fmt.Errorf("reconnect failed: %w", err)
				break // Can't continue without connection
			}

			// Retry the mailbox after reconnection
			fmt.Fprintf(s.output, "  ✓ Reconnected, retrying %s...\n", mbox)
			mboxResult = s.syncMailbox(mbox)
		}

		result.Mailboxes = append(result.Mailboxes, mboxResult)
		result.TotalNew += mboxResult.NewMsgs
		result.TotalSkipped += mboxResult.SkippedMsgs
		result.TotalDeleted += mboxResult.DeletedMsgs
		result.TotalDeduplicated += mboxResult.DeduplicatedMsgs
		result.FlagsUploaded += mboxResult.FlagsUploaded
		result.FlagsDownload += mboxResult.FlagsDownload
		result.TotalMoved += mboxResult.MovedMsgs
		result.NewMessageIDs = append(result.NewMessageIDs, mboxResult.NewMessageIDs...)

		if mboxResult.Error != nil && result.Error == nil {
			result.Error = mboxResult.Error
		}

		// Save state after each mailbox so progress survives interrupts (Ctrl+C)
		if !s.options.DryRun {
			if err := s.stateMgr.Save(s.account.Email, s.state); err != nil {
				fmt.Fprintf(s.output, "  Warning: failed to save state: %v\n", err)
			}
		}
	}

	// Backfill headers for existing messages (one-time operation)
	if s.options.BackfillHeaders && !s.options.DryRun {
		s.backfillHeaders(mailboxes)
	}

	result.Duration = time.Since(start)
	return result, nil
}

// selectedHeaders are the headers stored in message_headers for rule matching.
var selectedHeaders = []string{
	"List-Id", "List-Unsubscribe", "Precedence",
	"X-Mailer", "Return-Path", "X-GitHub-Reason",
	"Authentication-Results",
}

// backfillHeaders fetches headers from the IMAP server for messages that
// are already in the store but don't have entries in message_headers yet.
func (s *Syncer) backfillHeaders(mailboxes []string) {
	fmt.Fprintf(s.output, "  Backfilling headers...\n")

	for _, mboxName := range mailboxes {
		mboxState := s.state.GetMailboxState(mboxName)
		if _, err := s.client.SelectMailbox(mboxName); err != nil {
			slog.Debug("Backfill: skip mailbox", "module", "SYNC", "mailbox", mboxName, "err", err)
			continue
		}

		// Get all synced UIDs that have a Message-ID mapping
		var uidsToFetch []uint32
		for _, uid := range mboxState.SyncedUIDs {
			messageID, ok := mboxState.GetMessageID(uid)
			if !ok || messageID == "" {
				continue
			}
			// Check if this message already has headers in the DB
			dbID, err := s.store.GetMessageDBID(messageID, s.accountName())
			if err != nil || dbID == 0 {
				continue
			}
			if has, _ := s.store.HasHeaders(dbID); has {
				continue
			}
			uidsToFetch = append(uidsToFetch, uid)
		}

		if len(uidsToFetch) == 0 {
			continue
		}

		fmt.Fprintf(s.output, "    %s: fetching headers for %d messages...\n", mboxName, len(uidsToFetch))

		// Fetch in batches
		const batchSize = 500
		stored := 0
		for i := 0; i < len(uidsToFetch); i += batchSize {
			end := i + batchSize
			if end > len(uidsToFetch) {
				end = len(uidsToFetch)
			}
			batch := uidsToFetch[i:end]

			headers, err := s.client.FetchHeadersOnly(batch)
			if err != nil {
				slog.Debug("Backfill fetch failed", "module", "SYNC", "mailbox", mboxName, "err", err)
				continue
			}

			for uid, rawHeader := range headers {
				messageID, _ := mboxState.GetMessageID(uid)
				dbID, err := s.store.GetMessageDBID(messageID, s.accountName())
				if err != nil || dbID == 0 {
					continue
				}

				parsed, err := mail.ReadMessage(bytes.NewReader(append(rawHeader, '\r', '\n')))
				if err != nil {
					continue
				}

				for _, hdrName := range selectedHeaders {
					if v := parsed.Header.Get(hdrName); v != "" {
						_ = s.store.InsertHeader(dbID, strings.ToLower(hdrName), v)
					}
				}
				stored++
			}
		}

		fmt.Fprintf(s.output, "    ✓ %d messages backfilled\n", stored)
	}
}

// getMailboxesToSync returns the list of mailboxes to sync
func (s *Syncer) getMailboxesToSync() ([]string, error) {
	// If specific mailboxes are requested via CLI, use those
	if len(s.options.Mailboxes) > 0 {
		return s.options.Mailboxes, nil
	}

	// If explicit mailboxes are configured in config, use those
	if len(s.account.IMAP.Mailboxes) > 0 {
		configuredMailboxes := s.account.GetIMAPMailboxes()

		// List all mailboxes on server
		serverMailboxes, err := s.client.ListMailboxes()
		if err != nil {
			return nil, fmt.Errorf("failed to list mailboxes: %w", err)
		}

		// Match configured patterns against server mailboxes
		var result []string
		for _, serverMbox := range serverMailboxes {
			name := serverMbox.Name

			// Skip excluded mailboxes
			if config.IsIMAPMailboxExcluded(name) {
				continue
			}

			// Check if mailbox matches any configured pattern
			for _, pattern := range configuredMailboxes {
				if matchMailbox(name, pattern) {
					result = append(result, name)
					break
				}
			}
		}

		return result, nil
	}

	// No explicit config - use SPECIAL-USE auto-detection
	// This auto-detects localized folder names (e.g., "Gesendete Elemente" for Sent)
	mailboxes, err := s.client.GetSyncMailboxes()
	if err != nil {
		slog.Debug("SPECIAL-USE detection failed, falling back to defaults", "module", "SYNC", "err", err)
		// Fallback to default names (legacy behavior)
		return s.getMailboxesByName(config.DefaultIMAPMailboxes)
	}

	if len(mailboxes) == 0 {
		slog.Debug("No mailboxes detected via SPECIAL-USE, falling back to defaults", "module", "SYNC")
		return s.getMailboxesByName(config.DefaultIMAPMailboxes)
	}

	return mailboxes, nil
}

// getMailboxesByName finds mailboxes by matching against a list of names (legacy fallback)
func (s *Syncer) getMailboxesByName(names []string) ([]string, error) {
	serverMailboxes, err := s.client.ListMailboxes()
	if err != nil {
		return nil, fmt.Errorf("failed to list mailboxes: %w", err)
	}

	var result []string
	for _, serverMbox := range serverMailboxes {
		name := serverMbox.Name

		if config.IsIMAPMailboxExcluded(name) {
			continue
		}

		for _, pattern := range names {
			if matchMailbox(name, pattern) {
				result = append(result, name)
				break
			}
		}
	}

	return result, nil
}

// matchMailbox checks if a mailbox name matches a pattern
func matchMailbox(name, pattern string) bool {
	// Case-insensitive comparison
	nameLower := strings.ToLower(name)
	patternLower := strings.ToLower(pattern)

	// Exact match
	if nameLower == patternLower {
		return true
	}

	// Prefix match with word boundary (e.g., "Sent" matches "Sent Items" but not "SentBackup")
	if strings.HasPrefix(nameLower, patternLower) && len(nameLower) > len(patternLower) {
		next := nameLower[len(patternLower)]
		if next == ' ' || next == '/' {
			return true
		}
	}

	return false
}

// syncMailbox syncs a single mailbox
func (s *Syncer) syncMailbox(mailboxName string) MailboxResult {
	result := MailboxResult{Name: mailboxName}
	slog.Debug("Syncing mailbox", "module", "SYNC", "mailbox", mailboxName)

	// Select mailbox
	status, err := s.client.SelectMailbox(mailboxName)
	if err != nil {
		result.Error = err
		return result
	}
	result.TotalMsgs = status.Messages

	// Get mailbox state
	mboxState := s.state.GetMailboxState(mailboxName)

	// Check UIDVALIDITY
	if mboxState.NeedsFullResync(status.UidValidity) {
		fmt.Fprintf(s.output, "    UIDVALIDITY changed, performing full resync\n")
		mboxState.Reset(status.UidValidity)
	}
	mboxState.UIDValidity = status.UidValidity

	// Get all UIDs
	allUIDs, err := s.client.SearchAll()
	if err != nil {
		result.Error = fmt.Errorf("failed to search messages: %w", err)
		return result
	}
	slog.Debug("Total UIDs on server", "module", "SYNC", "count", len(allUIDs))

	// Get unsynced UIDs
	unsyncedUIDs := mboxState.GetUnsyncedUIDs(allUIDs)
	slog.Debug("Unsynced UIDs", "module", "SYNC", "count", len(unsyncedUIDs))

	// Check for deleted/moved messages (UIDs that are locally synced but no longer on server)
	deletedUIDs := mboxState.GetDeletedUIDs(allUIDs)
	if len(deletedUIDs) > 0 {
		if s.options.DryRun {
			fmt.Fprintf(s.output, "    Would remove %d deleted messages\n", len(deletedUIDs))
			result.DeletedMsgs = len(deletedUIDs)
		} else {
			// When a message disappears from a folder, remove that folder's tags
			// instead of deleting the message. The message may have been moved to
			// another folder (e.g. archived) and will reappear during that folder's sync.
			tagMapping := s.getFolderTagMapping(mailboxName)

			fmt.Fprintf(s.output, "  ✗ %s: %d removed\n", mailboxName, len(deletedUIDs))
			for _, uid := range deletedUIDs {
				messageID, hasID := mboxState.GetMessageID(uid)
				if hasID && messageID != "" {
					if tagMapping != nil && len(tagMapping.AddTags) > 0 {
						// Remove the folder's tags (reverse of adding them on download)
						slog.Debug("Removing folder tags for moved message", "module", "SYNC",
							"uid", uid, "message_id", messageID, "folder", mailboxName, "tags", tagMapping.AddTags)
						if err := s.store.ModifyTagsByMessageIDAndAccount(
							messageID, s.accountName(), nil, tagMapping.AddTags); err != nil {
							slog.Warn("remove tags failed", "module", "SYNC", "uid", uid, "err", err)
						}
					} else {
						// No tag mapping for this folder — delete the message
						slog.Debug("Deleting message removed from untagged folder", "module", "SYNC",
							"uid", uid, "message_id", messageID, "folder", mailboxName)
						if err := s.store.DeleteByMessageIDAndAccount(messageID, s.accountName()); err != nil {
							slog.Warn("store delete failed", "module", "SYNC", "uid", uid, "err", err)
						}
					}
				} else {
					slog.Debug("No Message-ID for deleted UID, skipping", "module", "SYNC", "uid", uid)
				}
				mboxState.RemoveSyncedUID(uid)
				result.DeletedMsgs++
			}
		}
	}

	if len(unsyncedUIDs) == 0 {
		// Still run flag sync even if no new messages
		// Flag sync runs even in dry-run mode to show what would happen
		if !s.options.NoFlags {
			uploaded, downloaded, movedMsgs := s.syncFlags(mailboxName, mboxState, allUIDs)
			result.FlagsUploaded = uploaded
			result.FlagsDownload = downloaded
			result.MovedMsgs = movedMsgs
		}
		return result
	}

	// Apply max messages limit
	maxMessages := s.account.GetIMAPMaxMessages()
	if maxMessages > 0 && len(unsyncedUIDs) > maxMessages {
		// Sort descending (newest first) and take the most recent
		sort.Slice(unsyncedUIDs, func(i, j int) bool {
			return unsyncedUIDs[i] > unsyncedUIDs[j]
		})
		unsyncedUIDs = unsyncedUIDs[:maxMessages]
		fmt.Fprintf(s.output, "    Limited to %d most recent messages\n", maxMessages)
	}

	// Deduplication: Check if messages already exist locally (moved from another folder)
	// Fetch Message-IDs for unsynced UIDs first
	var toDownload []uint32
	if !s.options.DryRun && len(unsyncedUIDs) > 0 {
		slog.Debug("Checking for duplicates among unsynced UIDs", "module", "SYNC", "count", len(unsyncedUIDs))

		// Fetch envelopes to get Message-IDs
		envelopes, err := s.client.FetchEnvelopes(unsyncedUIDs)
		if err != nil {
			slog.Debug("Failed to fetch envelopes for dedup", "module", "SYNC", "err", err)
			// Fall back to downloading everything
			toDownload = unsyncedUIDs
		} else {
			// Store ALL Message-IDs from envelopes now, so ensureMessageIDMapping
			// in syncFlags doesn't re-fetch them from the server
			for uid, messageID := range envelopes {
				if messageID != "" {
					mboxState.SetMessageID(uid, messageID)
				}
			}

			// Get folder tag mapping for this mailbox
			tagMapping := s.getFolderTagMapping(mailboxName)

			// Check each message for duplicates
			for _, uid := range unsyncedUIDs {
				messageID, hasID := envelopes[uid]
				if !hasID || messageID == "" {
					// No Message-ID, must download
					toDownload = append(toDownload, uid)
					continue
				}

				// Check if this message already exists in the store
				exists, err := s.store.MessageExistsForAccount(messageID, s.accountName())
				if err != nil {
					slog.Debug("Failed to check message existence", "module", "SYNC", "message_id", messageID, "err", err)
					toDownload = append(toDownload, uid)
					continue
				}

				if exists {
					// Message exists! Update tags instead of downloading
					slog.Debug("Message already exists, updating tags", "module", "SYNC", "uid", uid, "message_id", messageID)

					if tagMapping != nil {
						if err := s.store.ModifyTagsByMessageIDAndAccount(messageID, s.accountName(), tagMapping.AddTags, tagMapping.RemoveTags); err != nil {
							slog.Debug("Failed to update tags", "module", "SYNC", "message_id", messageID, "err", err)
						}
					} else if !strings.EqualFold(mailboxName, "INBOX") {
						// Custom folder with no special-use mapping — remove inbox tag
						// since the message was moved out of INBOX
						if err := s.store.ModifyTagsByMessageIDAndAccount(messageID, s.accountName(), nil, []string{"inbox"}); err != nil {
							slog.Debug("Failed to remove inbox tag", "module", "SYNC", "message_id", messageID, "err", err)
						}
					}

					// Update mailbox and UID to reflect the message's current server folder
					if err := s.store.UpdateMailbox(messageID, s.accountName(), mailboxName, uid); err != nil {
						slog.Debug("Failed to update mailbox", "module", "SYNC", "message_id", messageID, "err", err)
					}

					// Mark as synced (we don't need to download)
					mboxState.AddSyncedUID(uid)
					mboxState.SetMessageID(uid, messageID)
					result.DeduplicatedMsgs++
				} else {
					// Message doesn't exist, need to download
					toDownload = append(toDownload, uid)
				}
			}

			if result.DeduplicatedMsgs > 0 {
				fmt.Fprintf(s.output, "  ~ %s: %d deduplicated\n", mailboxName, result.DeduplicatedMsgs)
			}
		}
	} else {
		toDownload = unsyncedUIDs
	}

	// Nothing left to download after deduplication
	if len(toDownload) == 0 {
		if result.DeduplicatedMsgs > 0 || result.DeletedMsgs > 0 {
			// Still run flag sync
			if !s.options.NoFlags {
				uploaded, downloaded, movedMsgs := s.syncFlags(mailboxName, mboxState, allUIDs)
				result.FlagsUploaded = uploaded
				result.FlagsDownload = downloaded
				result.MovedMsgs = movedMsgs
			}
		}
		return result
	}

	// Fetch remaining messages in batches
	batchSize := s.account.GetIMAPBatchSize()
	totalBatches := (len(toDownload) + batchSize - 1) / batchSize

	for i := 0; i < len(toDownload); i += batchSize {
		end := i + batchSize
		if end > len(toDownload) {
			end = len(toDownload)
		}
		batch := toDownload[i:end]
		batchNum := (i / batchSize) + 1

		fmt.Fprintf(s.output, "  ↓ %s: batch %d/%d (%d-%d)...\n",
			mailboxName, batchNum, totalBatches, i+1, end)

		if s.options.DryRun {
			result.NewMsgs += len(batch)
			continue
		}

		// Fetch messages
		messages, err := s.client.FetchMessages(batch)
		if err != nil {
			fmt.Fprintf(s.output, "    Warning: batch fetch failed: %v\n", err)
			result.SkippedMsgs += len(batch)
			continue
		}

		// Write to maildir
		for _, msg := range messages {
			// Read message body once (io.Reader can only be read once)
			var msgBody []byte
			for _, literal := range msg.Body {
				data, err := io.ReadAll(literal)
				if err == nil {
					msgBody = data
					break
				}
			}

			if len(msgBody) == 0 {
				slog.Debug("Message has no body data", "module", "SYNC", "uid", msg.Uid)
				fmt.Fprintf(s.output, "    Warning: failed to write message %d: message has no body\n", msg.Uid)
				result.SkippedMsgs++
				continue
			}

			// Insert into SQLite store with eager tags
			if err := s.storeInsertMessage(mailboxName, msg, msgBody); err != nil {
				fmt.Fprintf(s.output, "    Warning: failed to store message %d: %v\n", msg.Uid, err)
				result.SkippedMsgs++
				continue
			}

			// Mark as synced in state (no more .uid marker files needed)
			mboxState.AddSyncedUID(msg.Uid)

			// Store initial flag state
			initialFlags := FlagStateFromIMAP(msg.Flags)
			mboxState.SetMessageFlags(msg.Uid, initialFlags)

			// Extract and store Message-ID for flag sync
			messageID := extractMessageIDFromBody(msgBody)
			if messageID != "" {
				mboxState.SetMessageID(msg.Uid, messageID)
				result.NewMessageIDs = append(result.NewMessageIDs, messageID)
			}

			result.NewMsgs++
		}
	}

	if result.NewMsgs > 0 {
		fmt.Fprintf(s.output, "  ✓ %s: %d new\n", mailboxName, result.NewMsgs)
	}

	// Flag synchronization (after message download)
	// Runs in all modes except when --no-flags is set
	// The syncFlags function internally respects the sync mode and dry-run for upload/download
	if !s.options.NoFlags {
		uploaded, downloaded, movedMsgs := s.syncFlags(mailboxName, mboxState, allUIDs)
		result.FlagsUploaded = uploaded
		result.FlagsDownload = downloaded
		result.MovedMsgs = movedMsgs
	}

	return result
}

// isConnectionError checks if an error indicates a lost connection
func isConnectionError(err error) bool {
	if err == nil {
		return false
	}
	errStr := err.Error()
	return strings.Contains(errStr, "connection closed") ||
		strings.Contains(errStr, "connection reset") ||
		strings.Contains(errStr, "broken pipe") ||
		strings.Contains(errStr, "EOF") ||
		strings.Contains(errStr, "timeout") ||
		strings.Contains(errStr, "use of closed network connection")
}

// ensureMessageIDMapping builds the UID<->MessageID mapping for all UIDs on server
// This is called once per mailbox and cached in state for future syncs
func (s *Syncer) ensureMessageIDMapping(mailboxName string, mboxState *MailboxState, allUIDs []uint32) error {
	// Check which UIDs are missing from mapping
	missingUIDs := mboxState.GetMissingMappingUIDs(allUIDs)

	if len(missingUIDs) == 0 {
		slog.Debug("All UIDs already mapped", "module", "SYNC", "count", len(allUIDs))
		return nil // All mapped
	}

	slog.Debug("Fetching Message-IDs for mapping", "module", "SYNC", "missing", len(missingUIDs), "total", len(allUIDs))

	// Fetch ENVELOPEs for missing UIDs (in batches)
	envelopes, err := s.client.FetchEnvelopes(missingUIDs)
	if err != nil {
		return fmt.Errorf("failed to fetch envelopes: %w", err)
	}

	// Store mappings
	mappedCount := 0
	for uid, messageID := range envelopes {
		if messageID != "" {
			mboxState.SetMessageID(uid, messageID)
			mappedCount++
		}
	}

	slog.Debug("Mapped new UIDs", "module", "SYNC", "count", mappedCount)
	return nil
}

// getFolderTagMapping returns the tag mapping for a mailbox based on SPECIAL-USE attributes
// Returns tags to add and remove when a mail is found in this folder
// Used for both new downloads and deduplication (updating tags for existing mails)
func (s *Syncer) getFolderTagMapping(mailboxName string) *FolderTagMapping {
	// Special case: INBOX always gets inbox tag
	if strings.EqualFold(mailboxName, "INBOX") {
		return &FolderTagMapping{
			AddTags:    []string{"inbox"},
			RemoveTags: []string{},
		}
	}

	// Find the mailbox in our cached list and check its SPECIAL-USE attributes
	for _, mbox := range s.serverMailboxes {
		if mbox.Name != mailboxName {
			continue
		}
		for _, attr := range mbox.Attributes {
			// Normalize attribute for lookup (case-insensitive)
			normalizedAttr := strings.ToLower(attr)
			for specialUse, mapping := range specialUseFolderTags {
				if strings.EqualFold(normalizedAttr, strings.ToLower(specialUse)) {
					return &mapping
				}
			}
		}
		break
	}

	// No special-use attribute — check if the folder name matches a known role fallback
	for role, fallbacks := range defaultRoleFallbacks {
		for _, name := range fallbacks {
			if strings.EqualFold(mailboxName, name) {
				roleStr := string(role)
				for specialUse, mapping := range specialUseFolderTags {
					if strings.EqualFold(roleStr, specialUse) {
						return &mapping
					}
				}
			}
		}
	}

	return nil
}

// syncFlags synchronizes flags between local store and IMAP server.
// Returns (flagsUploaded, flagsDownloaded, moved)
//
// This works for ALL messages on the server, not just those downloaded by durian.
// It builds a UID<->Message-ID mapping on first run (cached in state).
func (s *Syncer) syncFlags(mailboxName string, mboxState *MailboxState, allUIDs []uint32) (int, int, int) {
	var uploaded, downloaded, moved, flagErrors int

	if len(allUIDs) == 0 {
		return 0, 0, 0
	}

	// 1. Ensure we have Message-ID mapping for all UIDs
	if err := s.ensureMessageIDMapping(mailboxName, mboxState, allUIDs); err != nil {
		slog.Debug("Failed to build Message-ID mapping", "module", "SYNC", "err", err)
		// Continue anyway - we'll work with what we have
	}

	// 2. Fetch current flags from server for ALL UIDs
	serverFlags, err := s.client.FetchFlags(allUIDs)
	if err != nil {
		fmt.Fprintf(s.output, "    Warning: failed to fetch flags: %v\n", err)
		return 0, 0, 0
	}

	// 3. Get all local messages with tags in a single batch query
	slog.Debug("Starting flag sync", "module", "SYNC", "mailbox", mailboxName, "server_uids", len(allUIDs), "mapped_uids", mboxState.GetMappedUIDCount())

	localMessages, err := s.store.GetAllMessagesWithTags(mailboxName, s.accountName())
	if err != nil {
		slog.Debug("Failed to get messages from store", "module", "SYNC", "err", err)
		localMessages = make(map[string][]string)
	}
	slog.Debug("Local messages in folder", "module", "SYNC", "count", len(localMessages))

	// 5. For each UID on server, sync flags
	checkedCount := 0
	for _, uid := range allUIDs {
		messageID, hasMapping := mboxState.GetMessageID(uid)
		if !hasMapping || messageID == "" {
			continue // Can't sync without Message-ID
		}

		// Backfill UID for messages originally synced with uid=0
		_ = s.store.BackfillUID(messageID, s.accountName(), uid, mailboxName)

		// Check if message exists locally and get its tags
		tags, existsLocally := localMessages[messageID]
		if !existsLocally {
			continue // Message not in local folder
		}

		// Get server flags
		serverFlagList, ok := serverFlags[uid]
		if !ok {
			continue // Message not found on server (shouldn't happen)
		}
		serverState := FlagStateFromIMAP(serverFlagList)

		// Convert local tags to flag state
		localState := FlagStateFromTags(tags)

		checkedCount++

		// Get stored state (last sync baseline)
		storedState, hasStoredState := mboxState.GetMessageFlags(uid)

		if !hasStoredState {
			// First sync for this message - server is authoritative (no baseline to detect local changes)
			// Only download server flags to local; don't upload stale local state
			if !s.options.DryRun {
				mboxState.SetMessageFlags(uid, serverState)
			}

			if !localState.Equal(serverState) && s.options.Mode != SyncUploadOnly {
				if err := s.downloadFlagChanges(messageID, localState, serverState); err != nil {
					slog.Debug("Error downloading flags", "module", "SYNC", "uid", uid, "err", err)
					flagErrors++
				} else {
					downloaded++
					slog.Debug("First-sync downloaded flags", "module", "SYNC", "uid", uid, "message_id", messageID, "flags", serverState)
				}
			}
			continue
		}

		// Check for local changes (local differs from stored)
		if NeedsUpload(localState, storedState) && s.options.Mode != SyncDownloadOnly {
			if err := s.uploadFlagChanges(uid, localState, serverState); err != nil {
				slog.Debug("Error uploading flags", "module", "SYNC", "uid", uid, "err", err)
				flagErrors++
			} else {
				uploaded++
				slog.Debug("Uploaded flags", "module", "SYNC", "uid", uid, "from", storedState, "to", localState)
				// Update stored state (skip in dry-run)
				if !s.options.DryRun {
					mboxState.SetMessageFlags(uid, localState)
				}
			}
		}

		// Check for server changes (server differs from stored)
		if NeedsDownload(serverState, storedState) && s.options.Mode != SyncUploadOnly {
			// Check if local was also changed (conflict scenario)
			localChanged := NeedsUpload(localState, storedState)

			var targetState FlagState
			if localChanged {
				// Conflict: both local and server changed - merge (local wins)
				targetState = localState.Merge(serverState)
				slog.Debug("Flag conflict, merging", "module", "SYNC", "uid", uid)
			} else {
				// No local change - server wins (allows server to remove flags)
				targetState = serverState
			}

			if !targetState.Equal(localState) {
				if err := s.downloadFlagChanges(messageID, localState, targetState); err != nil {
					slog.Debug("Error downloading flags", "module", "SYNC", "uid", uid, "err", err)
					flagErrors++
				} else {
					downloaded++
					slog.Debug("Downloaded flags", "module", "SYNC", "uid", uid, "from", localState, "to", targetState)
				}
			}
			// Update stored state (skip in dry-run)
			if !s.options.DryRun {
				mboxState.SetMessageFlags(uid, targetState)
			}
		}
	}

	// Clean up stale inbox tags for messages no longer on server.
	// This catches messages that existed before durian (e.g., from mbsync) which
	// have no SyncedUID and thus aren't caught by GetDeletedUIDs.
	if strings.EqualFold(mailboxName, "INBOX") && !s.options.DryRun {
		serverMessageIDs := make(map[string]bool)
		for _, uid := range allUIDs {
			if messageID, ok := mboxState.GetMessageID(uid); ok && messageID != "" {
				serverMessageIDs[messageID] = true
			}
		}

		cleaned := 0
		for messageID, tags := range localMessages {
			hasInbox := false
			for _, tag := range tags {
				if tag == "inbox" {
					hasInbox = true
					break
				}
			}
			if hasInbox && !serverMessageIDs[messageID] {
				if err := s.store.ModifyTagsByMessageIDAndAccount(messageID, s.accountName(), nil, []string{"inbox"}); err != nil {
					slog.Debug("Failed to remove stale inbox tag", "module", "SYNC", "message_id", messageID, "err", err)
				} else {
					cleaned++
				}
			}
		}
		if cleaned > 0 {
			slog.Debug("Removed stale inbox tags", "module", "SYNC", "count", cleaned)
			slog.Debug("Removed stale inbox tags", "module", "SYNC", "count", cleaned)
		}
	}

	// Upload folder moves for INBOX messages that lost their "inbox" tag
	if strings.EqualFold(mailboxName, "INBOX") && s.options.Mode != SyncDownloadOnly {
		moved = s.uploadFolderMoves(mboxState, localMessages, allUIDs)
	}

	slog.Debug("Flag sync complete", "module", "SYNC", "checked", checkedCount, "uploaded", uploaded, "downloaded", downloaded, "moved", moved, "errors", flagErrors)

	if uploaded > 0 || downloaded > 0 || moved > 0 || flagErrors > 0 {
		if s.options.DryRun {
			fmt.Fprintf(s.output, "    ⚑ Flags: %d would upload, %d would download (dry-run)\n", uploaded, downloaded)
		} else if flagErrors > 0 {
			fmt.Fprintf(s.output, "    ⚑ Flags: %d uploaded, %d downloaded, %d moved, %d errors\n", uploaded, downloaded, moved, flagErrors)
		} else {
			fmt.Fprintf(s.output, "    ⚑ Flags: %d uploaded, %d downloaded, %d moved\n", uploaded, downloaded, moved)
		}
	}

	return uploaded, downloaded, moved
}

// folderMove represents a pending IMAP folder move operation.
type folderMove struct {
	uid       uint32
	messageID string
	dest      string // destination mailbox name
}

// uploadFolderMoves detects INBOX messages whose local tags no longer include
// "inbox" and moves them to the appropriate IMAP folder (Trash or Archive).
// Uses COPY + \Deleted + Expunge since go-imap v1 has no MOVE command.
// Returns the number of messages moved.
func (s *Syncer) uploadFolderMoves(mboxState *MailboxState, localMessages map[string][]string, allUIDs []uint32) int {
	// Build O(1) lookup set for server UIDs
	allUIDSet := make(map[uint32]struct{}, len(allUIDs))
	for _, uid := range allUIDs {
		allUIDSet[uid] = struct{}{}
	}

	// Scan for messages that lost the "inbox" tag
	var moves []folderMove
	for messageID, tags := range localMessages {
		hasInbox := false
		hasDeleted := false
		for _, tag := range tags {
			switch tag {
			case "inbox":
				hasInbox = true
			case "deleted":
				hasDeleted = true
			}
		}
		if hasInbox {
			continue // Still in inbox — nothing to do
		}

		// Resolve UID from state mapping
		uid, ok := mboxState.GetUIDByMessageID(messageID)
		if !ok || uid == 0 {
			continue // No UID mapping — can't move
		}
		if _, onServer := allUIDSet[uid]; !onServer {
			continue // Already gone from INBOX on server
		}

		// Pick destination
		dest := "archive"
		if hasDeleted {
			dest = "trash"
		}
		moves = append(moves, folderMove{uid: uid, messageID: messageID, dest: dest})
	}

	if len(moves) == 0 {
		return 0
	}

	// Lazily resolve destination mailbox names
	if s.trashMailbox == "" {
		if trash, err := s.client.FindTrashMailbox(); err == nil {
			s.trashMailbox = trash
			slog.Debug("Resolved trash mailbox", "module", "SYNC", "account", s.accountName(), "mailbox", trash)
		} else {
			slog.Warn("No trash mailbox found", "module", "SYNC", "account", s.accountName(), "err", err)
		}
	}
	if s.archiveMailbox == "" {
		if archive, err := s.client.FindArchiveMailbox(); err == nil {
			s.archiveMailbox = archive
			slog.Debug("Resolved archive mailbox", "module", "SYNC", "account", s.accountName(), "mailbox", archive)
		} else {
			slog.Warn("No archive mailbox found", "module", "SYNC", "account", s.accountName(), "err", err)
		}
	}

	moved := 0
	for _, m := range moves {
		destMailbox := s.archiveMailbox
		if m.dest == "trash" {
			destMailbox = s.trashMailbox
		}
		if destMailbox == "" {
			slog.Debug("No destination mailbox found, skipping move", "module", "SYNC", "account", s.accountName(), "uid", m.uid, "dest", m.dest)
			continue
		}

		if s.options.DryRun {
			slog.Debug("[dry-run] Would move message", "module", "SYNC", "uid", m.uid, "dest", destMailbox)
			moved++
			continue
		}

		// COPY to destination
		if err := s.client.CopyToMailbox(m.uid, destMailbox); err != nil {
			slog.Debug("Copy failed for folder move", "module", "SYNC", "uid", m.uid, "dest", destMailbox, "err", err)
			continue
		}

		// Set \Deleted on source (INBOX)
		if err := s.client.AddFlags(m.uid, []string{goimap.DeletedFlag}); err != nil {
			slog.Debug("AddFlags failed for folder move", "module", "SYNC", "uid", m.uid, "err", err)
			continue
		}

		// Expunge from INBOX
		if err := s.client.Expunge(); err != nil {
			slog.Debug("Expunge failed for folder move", "module", "SYNC", "uid", m.uid, "err", err)
		}

		// Clean up INBOX tracking state so next sync doesn't see this as "deleted from server"
		mboxState.RemoveSyncedUID(m.uid)

		moved++
		slog.Info("Moved message", "module", "SYNC", "uid", m.uid, "message_id", m.messageID, "dest", destMailbox)
	}

	if moved > 0 {
		fmt.Fprintf(s.output, "    ↗ Moved %d messages\n", moved)
	}

	return moved
}

// uploadFlagChanges uploads flag changes to the IMAP server
// For deleted messages: copies to Trash, sets \Deleted flag, and expunges
func (s *Syncer) uploadFlagChanges(uid uint32, local, server FlagState) error {
	// Check if this is a delete operation (deleted locally but not on server)
	isDelete := local.Deleted && !server.Deleted

	if isDelete {
		// Find and cache trash mailbox
		if s.trashMailbox == "" {
			trash, err := s.client.FindTrashMailbox()
			if err != nil {
				slog.Debug("Could not find trash mailbox", "module", "SYNC", "err", err)
				// Continue without copy - just set flag
			} else {
				s.trashMailbox = trash
				slog.Debug("Found trash mailbox", "module", "SYNC", "mailbox", trash)
			}
		}

		if s.options.DryRun {
			if s.trashMailbox != "" {
				slog.Debug("[dry-run] Would copy to trash, set \\Deleted, and expunge", "module", "SYNC", "uid", uid, "trash", s.trashMailbox)
			} else {
				slog.Debug("[dry-run] Would set \\Deleted and expunge (no trash mailbox)", "module", "SYNC", "uid", uid)
			}
			return nil
		}

		// Copy to trash first (if trash mailbox found)
		if s.trashMailbox != "" {
			if err := s.client.CopyToMailbox(uid, s.trashMailbox); err != nil {
				slog.Debug("Copy to trash failed", "module", "SYNC", "uid", uid, "err", err)
				return fmt.Errorf("copy to trash failed for UID %d: %w", uid, err)
			}
			slog.Debug("Copied to trash", "module", "SYNC", "uid", uid, "trash", s.trashMailbox)
		}

		// Set \Deleted flag (use AddFlags to preserve server-only keywords like $Completed)
		if err := s.client.AddFlags(uid, []string{goimap.DeletedFlag}); err != nil {
			return err
		}

		// Expunge to permanently remove from current mailbox
		if err := s.client.Expunge(); err != nil {
			slog.Debug("Expunge failed", "module", "SYNC", "err", err)
		}

		return nil
	}

	// Regular flag update — use AddFlags/RemoveFlags to preserve server-only
	// keywords like $Completed that ToIMAPFlags() doesn't include
	toAdd, toRemove := DiffFlags(local, server)

	if s.options.DryRun {
		slog.Debug("[dry-run] Would upload flags", "module", "SYNC", "uid", uid, "add", toAdd, "remove", toRemove)
		return nil
	}

	if err := s.client.AddFlags(uid, toAdd); err != nil {
		return err
	}
	return s.client.RemoveFlags(uid, toRemove)
}

// downloadFlagChanges downloads flag changes to store
func (s *Syncer) downloadFlagChanges(messageID string, current, target FlagState) error {
	if current.Equal(target) {
		return nil
	}

	addTags, removeTags := target.ToTagOps()

	if s.options.DryRun {
		slog.Debug("[dry-run] Would update tags", "module", "SYNC", "message_id", messageID, "add", addTags, "remove", removeTags)
		return nil
	}

	if err := s.store.ModifyTagsByMessageIDAndAccount(messageID, s.accountName(), addTags, removeTags); err != nil {
		return fmt.Errorf("store flag tag write: %w", err)
	}
	return nil
}

// accountName returns the account identifier (e.g. "work") used as the
// account column in the SQLite store.
func (s *Syncer) accountName() string {
	return s.account.AccountIdentifier()
}

// storeInsertMessage parses a raw email and inserts it into the SQLite store.
// Eagerly applies folder and content tags at insert time.
func (s *Syncer) storeInsertMessage(mailboxName string, imapMsg *goimap.Message, msgBody []byte) error {
	parsed, err := mail.ReadMessage(bytes.NewReader(msgBody))
	if err != nil {
		return fmt.Errorf("parse message: %w", err)
	}

	content := s.parser.Parse(parsed)
	messageID := strings.Trim(content.MessageID, "<>")
	if messageID == "" {
		// Generate synthetic Message-ID from UID + account to avoid losing the message
		messageID = fmt.Sprintf("durian-synthetic-%d-%s@%s", imapMsg.Uid, mailboxName, s.accountName())
		slog.Warn("Message has no Message-ID, using synthetic ID", "module", "SYNC",
			"uid", imapMsg.Uid, "mailbox", mailboxName, "synthetic_id", messageID)
	}

	var dateUnix int64
	if t, err := mail.ParseDate(content.Date); err == nil {
		dateUnix = t.Unix()
	} else {
		// Fallback to IMAP internal date
		dateUnix = imapMsg.InternalDate.Unix()
	}

	storeMsg := &store.Message{
		MessageID:   messageID,
		Subject:     content.Subject,
		FromAddr:    content.From,
		ToAddrs:     content.To,
		CCAddrs:     content.CC,
		InReplyTo:   content.InReplyTo,
		Refs:        content.References,
		BodyText:    content.Body,
		BodyHTML:    content.HTML,
		Date:        dateUnix,
		CreatedAt:   time.Now().Unix(),
		Mailbox:     mailboxName,
		Flags:       strings.Join(imapMsg.Flags, ","),
		UID:         imapMsg.Uid,
		Size:        len(msgBody),
		FetchedBody: true,
		Account:     s.accountName(),
	}

	if err := s.store.InsertMessage(storeMsg); err != nil {
		return fmt.Errorf("insert message: %w", err)
	}

	// Clear old attachments on upsert, then re-insert
	_ = s.store.DeleteAttachmentsByMessageDBID(storeMsg.ID)
	for i, att := range content.Attachments {
		partID := att.PartID
		if partID == 0 {
			partID = i + 1
		}
		if err := s.store.InsertAttachment(&store.Attachment{
			MessageDBID: storeMsg.ID,
			PartID:      partID,
			Filename:    att.Filename,
			ContentType: att.ContentType,
			Size:        att.Size,
			Disposition: att.Disposition,
			ContentID:   att.ContentID,
		}); err != nil {
			return fmt.Errorf("insert attachment %d: %w", i, err)
		}
	}

	// Store selected headers for rule matching and analysis
	for _, hdrName := range selectedHeaders {
		if v := parsed.Header.Get(hdrName); v != "" {
			_ = s.store.InsertHeader(storeMsg.ID, strings.ToLower(hdrName), v)
		}
	}

	// Eagerly apply folder tags (inbox, sent, trash, etc.)
	mapping := s.getFolderTagMapping(mailboxName)
	if mapping != nil {
		for _, tag := range mapping.AddTags {
			if err := s.store.AddTag(storeMsg.ID, tag); err != nil {
				return fmt.Errorf("add folder tag %q: %w", tag, err)
			}
		}
	}

	// Apply flag-based tags (unread, flagged, replied)
	flagState := FlagStateFromIMAP(imapMsg.Flags)
	flagAdd, _ := flagState.ToTagOps()
	for _, tag := range flagAdd {
		if err := s.store.AddTag(storeMsg.ID, tag); err != nil {
			return fmt.Errorf("add flag tag %q: %w", tag, err)
		}
	}

	// Eagerly detect calendar content
	if bytes.Contains(msgBody, []byte("text/calendar")) {
		if err := s.store.AddTag(storeMsg.ID, "cal"); err != nil {
			return fmt.Errorf("add cal tag: %w", err)
		}
	}

	// Apply user-defined filter rules
	if len(s.options.FilterRules) > 0 {
		matched := MatchingRules(s.options.FilterRules, storeMsg, len(content.Attachments), parsed.Header, s.accountName())
		for _, rule := range matched {
			for _, tag := range rule.AddTags {
				if err := s.store.AddTag(storeMsg.ID, tag); err != nil {
					return fmt.Errorf("add rule tag %q: %w", tag, err)
				}
			}
			for _, tag := range rule.RemoveTags {
				if err := s.store.RemoveTag(storeMsg.ID, tag); err != nil {
					return fmt.Errorf("remove rule tag %q: %w", tag, err)
				}
			}
			slog.Debug("Applied filter rule", "module", "SYNC", "rule", rule.Name, "message_id", messageID)
		}
	}

	return nil
}

// extractMessageIDFromBody extracts Message-ID from raw email body using net/mail
func extractMessageIDFromBody(body []byte) string {
	msg, err := mail.ReadMessage(bytes.NewReader(body))
	if err != nil {
		return ""
	}

	messageID := msg.Header.Get("Message-ID")
	if messageID == "" {
		messageID = msg.Header.Get("Message-Id")
	}

	// Remove < and > brackets
	return strings.Trim(messageID, "<>")
}

// SyncAccounts syncs multiple accounts
func SyncAccounts(accounts []*config.AccountConfig, options *SyncOptions) ([]*SyncResult, error) {
	var results []*SyncResult

	for _, account := range accounts {
		fmt.Fprintf(os.Stderr, "Syncing %s...\n", account.Email)

		syncer := NewSyncer(account, options)
		result, err := syncer.Sync()

		if err != nil {
			fmt.Fprintf(os.Stderr, "  ✗ %v\n", err)
			result = &SyncResult{
				Account: account.Email,
				Error:   err,
			}
		} else {
			// Compact summary
			parts := []string{}
			if result.TotalNew > 0 {
				parts = append(parts, fmt.Sprintf("%d new", result.TotalNew))
			}
			if result.TotalDeleted > 0 {
				parts = append(parts, fmt.Sprintf("%d deleted", result.TotalDeleted))
			}
			if result.TotalDeduplicated > 0 {
				parts = append(parts, fmt.Sprintf("%d dedup", result.TotalDeduplicated))
			}
			if result.FlagsUploaded > 0 || result.FlagsDownload > 0 {
				parts = append(parts, fmt.Sprintf("%d↑ %d↓ flags", result.FlagsUploaded, result.FlagsDownload))
			}
			if result.TotalMoved > 0 {
				parts = append(parts, fmt.Sprintf("%d moved", result.TotalMoved))
			}
			summary := "up to date"
			if len(parts) > 0 {
				summary = strings.Join(parts, ", ")
			}
			fmt.Fprintf(os.Stderr, "✓ %s (%.1fs)\n", summary, result.Duration.Seconds())
		}

		results = append(results, result)
	}

	return results, nil
}
