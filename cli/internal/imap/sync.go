package imap

import (
	"bytes"
	"fmt"
	"io"
	"net/mail"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	goimap "github.com/emersion/go-imap"

	"github.com/durian-dev/durian/cli/internal/config"
	"github.com/durian-dev/durian/cli/internal/debug"
	"github.com/durian-dev/durian/cli/internal/notmuch"
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
	DryRun    bool
	Quiet     bool
	NoNotmuch bool
	NoFlags   bool     // Skip flag synchronization
	Mode      SyncMode // Sync direction
	Mailboxes []string // Specific mailboxes to sync (empty = all)
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
	Error            error
}

// Syncer handles IMAP synchronization for an account
type Syncer struct {
	client          *Client
	maildir         *MaildirWriter
	notmuch         notmuch.Client
	state           *State
	stateMgr        *StateManager
	stateLock       *os.File             // File lock held during sync
	account         *config.AccountConfig
	options         *SyncOptions
	output          io.Writer
	trashMailbox    string                // Cached trash mailbox name for delete operations
	serverMailboxes []*goimap.MailboxInfo // Cached mailbox list for exclusion tags
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
		client:   NewClient(account),
		maildir:  NewMaildirWriter(account.GetIMAPMaildir()),
		notmuch:  notmuch.NewClient(""),
		stateMgr: NewStateManager(),
		account:  account,
		options:  options,
		output:   output,
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

	// Connect
	fmt.Fprintf(s.output, "  Connecting to %s:%d...\n", s.account.IMAP.Host, s.account.IMAP.Port)
	if err := s.client.Connect(); err != nil {
		return nil, err
	}
	defer s.client.Close()

	// Authenticate
	if err := s.client.Authenticate(); err != nil {
		return nil, err
	}

	authMethod := "password"
	if s.account.IMAP.Auth == "oauth2" {
		authMethod = "OAuth2"
	}
	fmt.Fprintf(s.output, "  ✓ Authenticated with %s\n", authMethod)

	// Get mailboxes to sync
	mailboxes, err := s.getMailboxesToSync()
	if err != nil {
		return nil, err
	}

	// Cache server mailbox list for exclusion tag logic
	s.serverMailboxes, err = s.client.ListMailboxes()
	if err != nil {
		debug.Log("Sync: failed to cache server mailbox list: %v (folder tags won't apply)", err)
	}

	// Sync each mailbox with automatic reconnection on failure
	for _, mbox := range mailboxes {
		mboxResult := s.syncMailbox(mbox)

		// Check if error is connection-related and try to reconnect
		if mboxResult.Error != nil && isConnectionError(mboxResult.Error) {
			debug.Log("Sync: connection lost during %s, attempting reconnect...", mbox)
			fmt.Fprintf(s.output, "  ⚠ Connection lost, reconnecting...\n")

			if err := s.client.Reconnect(); err != nil {
				debug.Log("Sync: reconnect failed: %v", err)
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

	// Run notmuch new (for new messages or after deletions)
	if !s.options.NoNotmuch && !s.options.DryRun && (result.TotalNew > 0 || result.TotalDeleted > 0) {
		fmt.Fprintf(s.output, "  Running notmuch new...\n")
		if err := runNotmuchNew(); err != nil {
			fmt.Fprintf(s.output, "  Warning: notmuch new failed: %v\n", err)
		} else {
			// Apply folder-based tags only after successful indexing
			// This sets inbox/trash/spam/sent/draft tags based on SPECIAL-USE folders
			for _, mboxResult := range result.Mailboxes {
				if mboxResult.NewMsgs > 0 {
					s.applyFolderTags(mboxResult.Name)
				}
			}
			// Apply content-based tags (e.g., calendar invitations)
			s.applyContentTags()
		}
	}

	result.Duration = time.Since(start)
	return result, nil
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
		debug.Log("getMailboxesToSync: SPECIAL-USE detection failed: %v, falling back to defaults", err)
		// Fallback to default names (legacy behavior)
		return s.getMailboxesByName(config.DefaultIMAPMailboxes)
	}

	if len(mailboxes) == 0 {
		debug.Log("getMailboxesToSync: no mailboxes detected via SPECIAL-USE, falling back to defaults")
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
	debug.Log("syncMailbox: %s", mailboxName)

	// Ensure maildir exists
	if !s.options.DryRun {
		if err := s.maildir.EnsureMailbox(mailboxName); err != nil {
			result.Error = fmt.Errorf("failed to create maildir: %w", err)
			return result
		}
	}

	// Select mailbox
	status, err := s.client.SelectMailbox(mailboxName)
	if err != nil {
		result.Error = err
		return result
	}
	result.TotalMsgs = status.Messages

	fmt.Fprintf(s.output, "  Syncing %s (%d messages)...\n", mailboxName, status.Messages)

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
	debug.Log("syncMailbox: %d total UIDs on server", len(allUIDs))

	// Get unsynced UIDs
	unsyncedUIDs := mboxState.GetUnsyncedUIDs(allUIDs)
	debug.Log("syncMailbox: %d unsynced UIDs", len(unsyncedUIDs))

	// Check for deleted/moved messages (UIDs that are locally synced but no longer on server)
	deletedUIDs := mboxState.GetDeletedUIDs(allUIDs)
	if len(deletedUIDs) > 0 {
		if s.options.DryRun {
			fmt.Fprintf(s.output, "    Would remove %d deleted messages\n", len(deletedUIDs))
			result.DeletedMsgs = len(deletedUIDs)
		} else {
			fmt.Fprintf(s.output, "    ✗ Removing %d deleted messages...\n", len(deletedUIDs))
			for _, uid := range deletedUIDs {
				// Get Message-ID from state to find the file
				messageID, hasID := mboxState.GetMessageID(uid)
				if hasID && messageID != "" {
					debug.Log("syncMailbox: removing deleted UID %d (Message-ID: %s)", uid, messageID)
					if err := s.notmuch.DeleteMessageFiles(messageID); err != nil {
						debug.Log("syncMailbox: failed to delete file for UID %d: %v", uid, err)
					}
					// Remove folder-specific tags when message disappears from this folder
					if strings.EqualFold(mailboxName, "INBOX") {
						_ = s.notmuch.ModifyTags(fmt.Sprintf("id:%s", messageID), nil, []string{"inbox"})
					}
				} else {
					debug.Log("syncMailbox: no Message-ID for deleted UID %d, skipping file deletion", uid)
				}
				mboxState.RemoveSyncedUID(uid)
				result.DeletedMsgs++
			}
		}
	}

	if len(unsyncedUIDs) == 0 {
		if result.DeletedMsgs == 0 {
			fmt.Fprintf(s.output, "    (up to date)\n")
		}
		// Still run flag sync even if no new messages
		// Flag sync runs even in dry-run mode to show what would happen
		if !s.options.NoFlags {
			uploaded, downloaded := s.syncFlags(mailboxName, mboxState, allUIDs)
			result.FlagsUploaded = uploaded
			result.FlagsDownload = downloaded
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
		debug.Log("syncMailbox: checking for duplicates among %d unsynced UIDs", len(unsyncedUIDs))

		// Fetch envelopes to get Message-IDs
		envelopes, err := s.client.FetchEnvelopes(unsyncedUIDs)
		if err != nil {
			debug.Log("syncMailbox: failed to fetch envelopes for dedup: %v", err)
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

				// Check if this message already exists in notmuch
				if s.notmuch.MessageExists(messageID) {
					// Message exists! Update tags instead of downloading
					debug.Log("syncMailbox: UID %d (Message-ID: %s) already exists, updating tags", uid, messageID)

					query := fmt.Sprintf("id:%s", messageID)
					if tagMapping != nil {
						if err := s.notmuch.ModifyTags(query, tagMapping.AddTags, tagMapping.RemoveTags); err != nil {
							debug.Log("syncMailbox: failed to update tags for %s: %v", messageID, err)
						}
					} else if !strings.EqualFold(mailboxName, "INBOX") {
						// Custom folder with no special-use mapping — remove inbox tag
						// since the message was moved out of INBOX
						if err := s.notmuch.ModifyTags(query, nil, []string{"inbox"}); err != nil {
							debug.Log("syncMailbox: failed to remove inbox tag for %s: %v", messageID, err)
						}
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
				fmt.Fprintf(s.output, "    ⚡ %d messages already exist (tags updated)\n", result.DeduplicatedMsgs)
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
				uploaded, downloaded := s.syncFlags(mailboxName, mboxState, allUIDs)
				result.FlagsUploaded = uploaded
				result.FlagsDownload = downloaded
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

		fmt.Fprintf(s.output, "    ↓ Batch %d/%d: Fetching messages %d-%d...\n",
			batchNum, totalBatches, i+1, end)

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
				debug.Log("syncMailbox: UID %d has no body data", msg.Uid)
				fmt.Fprintf(s.output, "    Warning: failed to write message %d: message has no body\n", msg.Uid)
				result.SkippedMsgs++
				continue
			}

			// Pass the already-read body to WriteMessage
			_, err := s.maildir.WriteMessage(mailboxName, msg, msgBody)
			if err != nil {
				fmt.Fprintf(s.output, "    Warning: failed to write message %d: %v\n", msg.Uid, err)
				result.SkippedMsgs++
				continue
			}

			// Mark as synced in state (no more .uid marker files needed)
			mboxState.AddSyncedUID(msg.Uid)

			// Store initial flag state
			initialFlags := FlagStateFromIMAP(msg.Flags)
			mboxState.SetMessageFlags(msg.Uid, initialFlags)

			// Extract and store Message-ID for flag sync
			if messageID := extractMessageIDFromBody(msgBody); messageID != "" {
				mboxState.SetMessageID(msg.Uid, messageID)
			}

			result.NewMsgs++
		}
	}

	if result.NewMsgs > 0 {
		fmt.Fprintf(s.output, "    ✓ %d new messages\n", result.NewMsgs)
		// Folder tags (inbox/trash/spam/etc.) are applied after notmuch new in the main Sync() loop
	}

	// Flag synchronization (after message download)
	// Runs in all modes except when --no-flags is set
	// The syncFlags function internally respects the sync mode and dry-run for upload/download
	if !s.options.NoFlags {
		uploaded, downloaded := s.syncFlags(mailboxName, mboxState, allUIDs)
		result.FlagsUploaded = uploaded
		result.FlagsDownload = downloaded
	}

	return result
}

// runNotmuchNew runs notmuch new to index new messages
func runNotmuchNew() error {
	cmd := exec.Command("notmuch", "new")
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	return cmd.Run()
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
		debug.Log("ensureMessageIDMapping: all %d UIDs already mapped", len(allUIDs))
		return nil // All mapped
	}

	debug.Log("ensureMessageIDMapping: fetching Message-IDs for %d/%d UIDs", len(missingUIDs), len(allUIDs))
	fmt.Fprintf(s.output, "    Building Message-ID mapping for %d messages...\n", len(missingUIDs))

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

	debug.Log("ensureMessageIDMapping: mapped %d new UIDs", mappedCount)
	return nil
}

// buildNotmuchFolderName converts IMAP mailbox name to notmuch folder path
// Example: Account maildir "~/.mail/habric" + mailbox "INBOX" -> "habric/INBOX"
func (s *Syncer) buildNotmuchFolderName(mailboxName string) string {
	maildirBase := s.account.GetIMAPMaildir()
	// Get the account folder name (last part of maildir path)
	accountFolder := filepath.Base(maildirBase)
	// Combine: accountFolder/mailboxName
	return filepath.Join(accountFolder, mailboxName)
}

// applyFolderTags applies folder-based tags to all messages in a mailbox
// Uses SPECIAL-USE attributes to determine which tags to add/remove
// Called after notmuch new to tag newly indexed messages
func (s *Syncer) applyFolderTags(mailboxName string) {
	mapping := s.getFolderTagMapping(mailboxName)
	if mapping == nil || (len(mapping.AddTags) == 0 && len(mapping.RemoveTags) == 0) {
		return
	}

	// Build notmuch folder query
	folderPath := s.buildNotmuchFolderName(mailboxName)
	query := fmt.Sprintf("folder:\"%s\"", folderPath)

	if err := s.notmuch.ModifyTags(query, mapping.AddTags, mapping.RemoveTags); err != nil {
		debug.Log("applyFolderTags: failed to apply tags to %s: %v", mailboxName, err)
	} else {
		debug.Log("applyFolderTags: applied +%v -%v to %s", mapping.AddTags, mapping.RemoveTags, mailboxName)
	}
}

// applyContentTags tags messages based on content type (e.g., calendar invitations).
// This is idempotent: messages already tagged are excluded by the query.
func (s *Syncer) applyContentTags() {
	if err := s.notmuch.ModifyTags("mimetype:text/calendar AND NOT tag:cal", []string{"cal"}, nil); err != nil {
		debug.Log("applyContentTags: failed to tag calendar messages: %v", err)
	}
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

	// No special-use attribute found - no tag changes
	return nil
}

// syncFlags synchronizes flags between local notmuch and IMAP server
// Returns (flagsUploaded, flagsDownloaded)
//
// This now works for ALL messages on the server, not just those downloaded by durian.
// It builds a UID<->Message-ID mapping on first run (cached in state).
func (s *Syncer) syncFlags(mailboxName string, mboxState *MailboxState, allUIDs []uint32) (int, int) {
	var uploaded, downloaded, flagErrors int

	if len(allUIDs) == 0 {
		return 0, 0
	}

	// 1. Ensure we have Message-ID mapping for all UIDs
	if err := s.ensureMessageIDMapping(mailboxName, mboxState, allUIDs); err != nil {
		debug.Log("syncFlags: warning - failed to build Message-ID mapping: %v", err)
		// Continue anyway - we'll work with what we have
	}

	// 2. Fetch current flags from server for ALL UIDs
	serverFlags, err := s.client.FetchFlags(allUIDs)
	if err != nil {
		fmt.Fprintf(s.output, "    Warning: failed to fetch flags: %v\n", err)
		return 0, 0
	}

	// 3. Build folder path for notmuch query
	folderName := s.buildNotmuchFolderName(mailboxName)
	debug.Log("syncFlags: folder=%s, %d UIDs on server, %d with mapping",
		folderName, len(allUIDs), mboxState.GetMappedUIDCount())

	// 4. Get all local messages with tags in a single batch query
	// This is much faster than calling GetTags() for each message individually
	localMessages, err := s.notmuch.GetAllMessagesWithTags(folderName)
	if err != nil {
		debug.Log("syncFlags: warning - failed to get local messages: %v", err)
		localMessages = make(map[string][]string) // Continue with empty map
	}
	debug.Log("syncFlags: %d local messages in folder", len(localMessages))

	// 5. For each UID on server, sync flags
	checkedCount := 0
	for _, uid := range allUIDs {
		messageID, hasMapping := mboxState.GetMessageID(uid)
		if !hasMapping || messageID == "" {
			continue // Can't sync without Message-ID
		}

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
		localState := FlagStateFromNotmuchTags(tags)

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
					debug.Log("syncFlags: error downloading flags for UID %d: %v", uid, err)
					flagErrors++
				} else {
					downloaded++
					debug.Log("syncFlags: first-sync downloaded flags for UID %d (Message-ID: %s): %+v", uid, messageID, serverState)
				}
			}
			continue
		}

		// Check for local changes (local differs from stored)
		if NeedsUpload(localState, storedState) && s.options.Mode != SyncDownloadOnly {
			if err := s.uploadFlagChanges(uid, localState, serverState); err != nil {
				debug.Log("syncFlags: error uploading flags for UID %d: %v", uid, err)
				flagErrors++
			} else {
				uploaded++
				debug.Log("syncFlags: uploaded flags for UID %d: %+v -> %+v", uid, storedState, localState)
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
				debug.Log("syncFlags: conflict for UID %d - merging local and server changes", uid)
			} else {
				// No local change - server wins (allows server to remove flags)
				targetState = serverState
			}

			if !targetState.Equal(localState) {
				if err := s.downloadFlagChanges(messageID, localState, targetState); err != nil {
					debug.Log("syncFlags: error downloading flags for UID %d: %v", uid, err)
					flagErrors++
				} else {
					downloaded++
					debug.Log("syncFlags: downloaded flags for UID %d: %+v -> %+v", uid, localState, targetState)
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
				if err := s.notmuch.ModifyTags(fmt.Sprintf("id:%s", messageID), nil, []string{"inbox"}); err != nil {
					debug.Log("syncFlags: failed to remove stale inbox tag for %s: %v", messageID, err)
				} else {
					cleaned++
				}
			}
		}
		if cleaned > 0 {
			debug.Log("syncFlags: removed stale inbox tag from %d messages", cleaned)
			fmt.Fprintf(s.output, "    ✗ Removed stale inbox tag from %d messages\n", cleaned)
		}
	}

	debug.Log("syncFlags: checked %d messages, uploaded %d, downloaded %d, errors %d", checkedCount, uploaded, downloaded, flagErrors)

	if uploaded > 0 || downloaded > 0 || flagErrors > 0 {
		if s.options.DryRun {
			fmt.Fprintf(s.output, "    ⚑ Flags: %d would upload, %d would download (dry-run)\n", uploaded, downloaded)
		} else if flagErrors > 0 {
			fmt.Fprintf(s.output, "    ⚑ Flags: %d uploaded, %d downloaded, %d errors\n", uploaded, downloaded, flagErrors)
		} else {
			fmt.Fprintf(s.output, "    ⚑ Flags: %d uploaded, %d downloaded\n", uploaded, downloaded)
		}
	}

	return uploaded, downloaded
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
				debug.Log("uploadFlagChanges: could not find trash mailbox: %v", err)
				// Continue without copy - just set flag
			} else {
				s.trashMailbox = trash
				debug.Log("uploadFlagChanges: found trash mailbox: %s", trash)
			}
		}

		if s.options.DryRun {
			if s.trashMailbox != "" {
				debug.Log("syncFlags: [dry-run] would copy UID %d to %s, set \\Deleted, and expunge", uid, s.trashMailbox)
			} else {
				debug.Log("syncFlags: [dry-run] would set \\Deleted on UID %d and expunge (no trash mailbox found)", uid)
			}
			return nil
		}

		// Copy to trash first (if trash mailbox found)
		if s.trashMailbox != "" {
			if err := s.client.CopyToMailbox(uid, s.trashMailbox); err != nil {
				debug.Log("uploadFlagChanges: copy to trash failed: %v", err)
				return fmt.Errorf("copy to trash failed for UID %d: %w", uid, err)
			}
			debug.Log("uploadFlagChanges: copied UID %d to %s", uid, s.trashMailbox)
		}

		// Set \Deleted flag (use AddFlags to preserve server-only keywords like $Completed)
		if err := s.client.AddFlags(uid, []string{goimap.DeletedFlag}); err != nil {
			return err
		}

		// Expunge to permanently remove from current mailbox
		if err := s.client.Expunge(); err != nil {
			debug.Log("uploadFlagChanges: expunge failed: %v", err)
		}

		return nil
	}

	// Regular flag update — use AddFlags/RemoveFlags to preserve server-only
	// keywords like $Completed that ToIMAPFlags() doesn't include
	toAdd, toRemove := DiffFlags(local, server)

	if s.options.DryRun {
		debug.Log("syncFlags: [dry-run] would upload flags for UID %d: add=%v remove=%v", uid, toAdd, toRemove)
		return nil
	}

	if err := s.client.AddFlags(uid, toAdd); err != nil {
		return err
	}
	return s.client.RemoveFlags(uid, toRemove)
}

// downloadFlagChanges downloads flag changes to notmuch
func (s *Syncer) downloadFlagChanges(messageID string, current, target FlagState) error {
	// Only update if there are actual changes
	if current.Equal(target) {
		return nil
	}

	addTags, removeTags := target.ToNotmuchTags()

	if s.options.DryRun {
		debug.Log("syncFlags: [dry-run] would update tags for %s: add=%v remove=%v", messageID, addTags, removeTags)
		return nil
	}

	return s.notmuch.ModifyTags("id:"+messageID, addTags, removeTags)
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
			fmt.Fprintf(os.Stderr, "  Error: %v\n", err)
			result = &SyncResult{
				Account: account.Email,
				Error:   err,
			}
		} else {
			fmt.Fprintf(os.Stderr, "✓ Sync completed in %.1fs\n\n", result.Duration.Seconds())
		}

		results = append(results, result)
	}

	return results, nil
}
