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
	Account       string
	Mailboxes     []MailboxResult
	Duration      time.Duration
	TotalNew      int
	TotalSkipped  int
	FlagsUploaded int // Flags uploaded to server
	FlagsDownload int // Flags downloaded from server
	Error         error
}

// MailboxResult contains the results for a single mailbox
type MailboxResult struct {
	Name          string
	TotalMsgs     uint32
	NewMsgs       int
	SkippedMsgs   int
	FlagsUploaded int
	FlagsDownload int
	Error         error
}

// Syncer handles IMAP synchronization for an account
type Syncer struct {
	client       *Client
	maildir      *MaildirWriter
	notmuch      *notmuch.Client
	state        *State
	stateMgr     *StateManager
	account      *config.AccountConfig
	options      *SyncOptions
	output       io.Writer
	trashMailbox string // Cached trash mailbox name for delete operations
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

	// Load state
	var err error
	s.state, err = s.stateMgr.Load(s.account.Email)
	if err != nil {
		return nil, fmt.Errorf("failed to load state: %w", err)
	}

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

	// Sync each mailbox
	for _, mbox := range mailboxes {
		mboxResult := s.syncMailbox(mbox)
		result.Mailboxes = append(result.Mailboxes, mboxResult)
		result.TotalNew += mboxResult.NewMsgs
		result.TotalSkipped += mboxResult.SkippedMsgs
		result.FlagsUploaded += mboxResult.FlagsUploaded
		result.FlagsDownload += mboxResult.FlagsDownload

		if mboxResult.Error != nil && result.Error == nil {
			result.Error = mboxResult.Error
		}
	}

	// Save state
	if !s.options.DryRun {
		if err := s.stateMgr.Save(s.account.Email, s.state); err != nil {
			fmt.Fprintf(s.output, "  Warning: failed to save state: %v\n", err)
		}
	}

	// Run notmuch new
	if !s.options.NoNotmuch && !s.options.DryRun && result.TotalNew > 0 {
		fmt.Fprintf(s.output, "  Running notmuch new...\n")
		if err := runNotmuchNew(); err != nil {
			fmt.Fprintf(s.output, "  Warning: notmuch new failed: %v\n", err)
		}
	}

	result.Duration = time.Since(start)
	return result, nil
}

// getMailboxesToSync returns the list of mailboxes to sync
func (s *Syncer) getMailboxesToSync() ([]string, error) {
	// If specific mailboxes are requested, use those
	if len(s.options.Mailboxes) > 0 {
		return s.options.Mailboxes, nil
	}

	// Get configured mailboxes or defaults
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

// matchMailbox checks if a mailbox name matches a pattern
func matchMailbox(name, pattern string) bool {
	// Case-insensitive comparison
	nameLower := strings.ToLower(name)
	patternLower := strings.ToLower(pattern)

	// Exact match
	if nameLower == patternLower {
		return true
	}

	// Prefix match (e.g., "Sent" matches "Sent Items")
	if strings.HasPrefix(nameLower, patternLower) {
		return true
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

	if len(unsyncedUIDs) == 0 {
		fmt.Fprintf(s.output, "    (up to date)\n")
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

	// Fetch in batches
	batchSize := s.account.GetIMAPBatchSize()
	totalBatches := (len(unsyncedUIDs) + batchSize - 1) / batchSize

	for i := 0; i < len(unsyncedUIDs); i += batchSize {
		end := i + batchSize
		if end > len(unsyncedUIDs) {
			end = len(unsyncedUIDs)
		}
		batch := unsyncedUIDs[i:end]
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
			key, err := s.maildir.WriteMessage(mailboxName, msg, msgBody)
			if err != nil {
				fmt.Fprintf(s.output, "    Warning: failed to write message %d: %v\n", msg.Uid, err)
				result.SkippedMsgs++
				continue
			}

			// Mark as synced
			mboxState.AddSyncedUID(msg.Uid)
			s.maildir.MarkMessageSynced(mailboxName, msg.Uid, key)

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

// syncFlags synchronizes flags between local notmuch and IMAP server
// Returns (flagsUploaded, flagsDownloaded)
//
// This now works for ALL messages on the server, not just those downloaded by durian.
// It builds a UID<->Message-ID mapping on first run (cached in state).
func (s *Syncer) syncFlags(mailboxName string, mboxState *MailboxState, allUIDs []uint32) (int, int) {
	var uploaded, downloaded int

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

	// 4. Get all local message IDs in this folder from notmuch
	localMessageIDs, err := s.notmuch.GetAllMessageIDs(folderName)
	if err != nil {
		debug.Log("syncFlags: warning - failed to get local messages: %v", err)
		// Continue - some messages might still be syncable via other means
	}

	// Build set for quick lookup
	localMessageSet := make(map[string]bool)
	for _, id := range localMessageIDs {
		localMessageSet[id] = true
	}
	debug.Log("syncFlags: %d local messages in folder", len(localMessageIDs))

	// 5. For each UID on server, sync flags
	checkedCount := 0
	for _, uid := range allUIDs {
		messageID, hasMapping := mboxState.GetMessageID(uid)
		if !hasMapping || messageID == "" {
			continue // Can't sync without Message-ID
		}

		// Check if message exists locally
		if !localMessageSet[messageID] {
			continue // Message not in local folder
		}

		// Get server flags
		serverFlagList, ok := serverFlags[uid]
		if !ok {
			continue // Message not found on server (shouldn't happen)
		}
		serverState := FlagStateFromIMAP(serverFlagList)

		// Get local flags from notmuch
		tags, err := s.notmuch.GetTags(messageID)
		if err != nil {
			continue // Message not in notmuch (shouldn't happen if in localMessageSet)
		}
		localState := FlagStateFromNotmuchTags(tags)

		checkedCount++

		// Get stored state (last sync baseline)
		storedState, hasStoredState := mboxState.GetMessageFlags(uid)

		if !hasStoredState {
			// First sync for this message - establish baseline
			merged := localState.Merge(serverState)
			if !s.options.DryRun {
				mboxState.SetMessageFlags(uid, merged)
			}

			// If local and server differ, sync them
			if !localState.Equal(serverState) {
				// Upload local changes to server
				if s.options.Mode != SyncDownloadOnly {
					if err := s.uploadFlagChanges(uid, localState, serverState); err == nil {
						uploaded++
						debug.Log("syncFlags: uploaded flags for UID %d (Message-ID: %s): %+v", uid, messageID, localState)
					}
				}
				// Download server changes to local
				if s.options.Mode != SyncUploadOnly {
					if err := s.downloadFlagChanges(messageID, localState, serverState); err == nil {
						downloaded++
					}
				}
			}
			continue
		}

		// Check for local changes (local differs from stored)
		if NeedsUpload(localState, storedState) && s.options.Mode != SyncDownloadOnly {
			if err := s.uploadFlagChanges(uid, localState, serverState); err == nil {
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
			// Merge: apply server changes that weren't overridden locally
			merged := localState.Merge(serverState)
			if !merged.Equal(localState) {
				if err := s.downloadFlagChanges(messageID, localState, merged); err == nil {
					downloaded++
				}
			}
			// Update stored state with merged result (skip in dry-run)
			if !s.options.DryRun {
				mboxState.SetMessageFlags(uid, merged)
			}
		}
	}

	debug.Log("syncFlags: checked %d messages, uploaded %d, downloaded %d", checkedCount, uploaded, downloaded)

	if uploaded > 0 || downloaded > 0 {
		if s.options.DryRun {
			fmt.Fprintf(s.output, "    ⚑ Flags: %d would upload, %d would download (dry-run)\n", uploaded, downloaded)
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
				// Continue anyway - at least set the deleted flag
			} else {
				debug.Log("uploadFlagChanges: copied UID %d to %s", uid, s.trashMailbox)
			}
		}

		// Set \Deleted flag
		if err := s.client.StoreFlags(uid, local.ToIMAPFlags()); err != nil {
			return err
		}

		// Expunge to permanently remove from current mailbox
		if err := s.client.Expunge(); err != nil {
			debug.Log("uploadFlagChanges: expunge failed: %v", err)
			// Not a fatal error - message is marked deleted
		}

		return nil
	}

	// Regular flag update (not a delete)
	newFlags := local.ToIMAPFlags()

	if s.options.DryRun {
		debug.Log("syncFlags: [dry-run] would upload flags for UID %d: %v", uid, newFlags)
		return nil
	}

	return s.client.StoreFlags(uid, newFlags)
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

	query := "id:" + messageID

	if len(addTags) > 0 {
		if err := s.notmuch.AddTags(query, addTags...); err != nil {
			return err
		}
	}

	if len(removeTags) > 0 {
		if err := s.notmuch.RemoveTags(query, removeTags...); err != nil {
			return err
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
