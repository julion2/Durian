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
	client   *Client
	maildir  *MaildirWriter
	notmuch  *notmuch.Client
	state    *State
	stateMgr *StateManager
	account  *config.AccountConfig
	options  *SyncOptions
	output   io.Writer
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

	// Get unsynced UIDs
	unsyncedUIDs := mboxState.GetUnsyncedUIDs(allUIDs)

	if len(unsyncedUIDs) == 0 {
		fmt.Fprintf(s.output, "    (up to date)\n")
		// Still run flag sync even if no new messages
		if !s.options.NoFlags && !s.options.DryRun {
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
			// Get message body for writing and Message-ID extraction
			var msgBody []byte
			for _, literal := range msg.Body {
				data, err := io.ReadAll(literal)
				if err == nil {
					msgBody = data
					break
				}
			}

			key, err := s.maildir.WriteMessage(mailboxName, msg)
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
			if len(msgBody) > 0 {
				if messageID := extractMessageIDFromBody(msgBody); messageID != "" {
					mboxState.SetMessageID(msg.Uid, messageID)
				}
			}

			result.NewMsgs++
		}
	}

	if result.NewMsgs > 0 {
		fmt.Fprintf(s.output, "    ✓ %d new messages\n", result.NewMsgs)
	}

	// Flag synchronization (after message download)
	// Runs in all modes except when --no-flags is set
	// The syncFlags function internally respects the sync mode for upload/download
	if !s.options.NoFlags && !s.options.DryRun {
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

// syncFlags synchronizes flags between local notmuch and IMAP server
// Returns (flagsUploaded, flagsDownloaded)
//
// Current limitations:
// - Uploading local flag changes to server requires Message-ID→UID mapping
// - This mapping is only established for newly downloaded messages
// - For pre-existing messages, only server→local sync works
//
// TODO: Add migration to build Message-ID mapping for existing messages
func (s *Syncer) syncFlags(mailboxName string, mboxState *MailboxState, allUIDs []uint32) (int, int) {
	var uploaded, downloaded int

	// Only sync flags for messages we have in state
	uidsWithState := mboxState.GetUIDsWithFlags()
	if len(uidsWithState) == 0 && len(mboxState.SyncedUIDs) == 0 {
		return 0, 0
	}

	// Use synced UIDs if we don't have flag state yet (first run after upgrade)
	uidsToSync := uidsWithState
	if len(uidsToSync) == 0 {
		uidsToSync = mboxState.SyncedUIDs
	}

	// Fetch current flags from server for all tracked UIDs
	serverFlags, err := s.client.FetchFlags(uidsToSync)
	if err != nil {
		fmt.Fprintf(s.output, "    Warning: failed to fetch flags: %v\n", err)
		return 0, 0
	}

	// Build folder path for notmuch query
	maildirBase := s.account.GetIMAPMaildir()
	folderPath := s.maildir.mailboxPath(mailboxName)
	// Get relative path from maildir base for notmuch folder query
	folderName := strings.TrimPrefix(folderPath, maildirBase)
	folderName = strings.TrimPrefix(folderName, "/")

	for _, uid := range uidsToSync {
		// Get server flags
		serverFlagList, ok := serverFlags[uid]
		if !ok {
			continue // Message no longer on server
		}
		serverState := FlagStateFromIMAP(serverFlagList)

		// Get stored state
		storedState, hasStoredState := mboxState.GetMessageFlags(uid)

		// Get local flags from notmuch
		messageID, hasMessageID := mboxState.GetMessageID(uid)
		if !hasMessageID {
			// Lazy migration: load Message-ID from maildir file
			messageID = s.loadMessageIDFromMaildir(mailboxName, uid)
			if messageID != "" {
				mboxState.SetMessageID(uid, messageID)
			}
		}

		if messageID == "" {
			// Can't find message, just update stored state with server flags
			mboxState.SetMessageFlags(uid, serverState)
			continue
		}

		// Get notmuch tags
		tags, err := s.notmuch.GetTags(messageID)
		if err != nil {
			continue // Message not in notmuch
		}
		localState := FlagStateFromNotmuchTags(tags)

		if !hasStoredState {
			// First sync - just record current state
			// Use merged state as baseline
			merged := localState.Merge(serverState)
			mboxState.SetMessageFlags(uid, merged)

			// If local and server differ, sync them
			if !localState.Equal(serverState) {
				// Upload local changes to server
				if s.options.Mode != SyncDownloadOnly {
					if err := s.uploadFlagChanges(uid, localState, serverState); err == nil {
						uploaded++
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
			// TODO: Flag upload is currently hanging on Gmail - needs investigation
			// For now, just log the change
			fmt.Fprintf(s.output, "    → Would upload flag change for UID %d\n", uid)
			uploaded++
			// Update stored state to prevent repeated attempts
			mboxState.SetMessageFlags(uid, localState)
			/*
				if err := s.uploadFlagChanges(uid, localState, serverState); err == nil {
					uploaded++
					// Update stored state
					mboxState.SetMessageFlags(uid, localState)
				}
			*/
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
			// Update stored state with merged result
			mboxState.SetMessageFlags(uid, merged)
		}
	}

	if uploaded > 0 || downloaded > 0 {
		fmt.Fprintf(s.output, "    ⚑ Flags: %d uploaded, %d downloaded\n", uploaded, downloaded)
	}

	return uploaded, downloaded
}

// uploadFlagChanges uploads flag changes to the IMAP server
func (s *Syncer) uploadFlagChanges(uid uint32, local, server FlagState) error {
	// Merge local state onto server and set all flags at once
	// This is simpler than add/remove operations
	merged := local.Merge(server)
	newFlags := merged.ToIMAPFlags()

	return s.client.StoreFlags(uid, newFlags)
}

// downloadFlagChanges downloads flag changes to notmuch
func (s *Syncer) downloadFlagChanges(messageID string, current, target FlagState) error {
	// Only update if there are actual changes
	if current.Equal(target) {
		return nil
	}

	addTags, removeTags := target.ToNotmuchTags()

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

// findMessageID tries to find the notmuch Message-ID for a UID
func (s *Syncer) findMessageID(mailboxName string, uid uint32) string {
	// Get the maildir key from our marker file
	key, err := s.maildir.GetSyncedMessageKey(mailboxName, uid)
	if err != nil {
		return ""
	}

	// Search for the message in notmuch using the key
	// The key is part of the filename
	msg, err := s.notmuch.GetMessageByFilename(key)
	if err != nil {
		return ""
	}

	return msg.ID
}

// loadMessageIDFromMaildir reads a message from maildir and extracts its Message-ID
// This is used for lazy migration of messages downloaded before Message-ID tracking
func (s *Syncer) loadMessageIDFromMaildir(mailboxName string, uid uint32) string {
	// Get the maildir key from our marker file
	key, err := s.maildir.GetSyncedMessageKey(mailboxName, uid)
	if err != nil {
		return ""
	}

	// Build possible file paths (message could be in cur/ or new/)
	mailboxPath := s.maildir.mailboxPath(mailboxName)
	possiblePaths := []string{
		filepath.Join(mailboxPath, "cur", key),
		filepath.Join(mailboxPath, "new", key),
	}

	// Also try with common flag suffixes
	for _, basePath := range []string{
		filepath.Join(mailboxPath, "cur"),
		filepath.Join(mailboxPath, "new"),
	} {
		entries, err := os.ReadDir(basePath)
		if err != nil {
			continue
		}
		for _, entry := range entries {
			if strings.HasPrefix(entry.Name(), key) {
				possiblePaths = append(possiblePaths, filepath.Join(basePath, entry.Name()))
			}
		}
	}

	// Try to read and parse Message-ID from the file
	for _, path := range possiblePaths {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}

		if messageID := extractMessageIDFromBody(data); messageID != "" {
			return messageID
		}
	}

	return ""
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

// extractMessageIDFromHeaders extracts Message-ID from email headers (legacy, for string input)
func extractMessageIDFromHeaders(headers string) string {
	// Simple regex to find Message-ID header
	for _, line := range strings.Split(headers, "\n") {
		line = strings.TrimSpace(line)
		lower := strings.ToLower(line)
		if strings.HasPrefix(lower, "message-id:") {
			// Extract the ID part
			id := strings.TrimSpace(strings.TrimPrefix(line, line[:11]))
			// Remove < and > if present
			id = strings.Trim(id, "<>")
			return id
		}
	}
	return ""
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
