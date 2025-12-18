package imap

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"sort"
	"strings"
	"time"

	"github.com/durian-dev/durian/cli/internal/config"
)

// SyncOptions configures the sync behavior
type SyncOptions struct {
	DryRun    bool
	Quiet     bool
	NoNotmuch bool
	Mailboxes []string // Specific mailboxes to sync (empty = all)
}

// SyncResult contains the results of a sync operation
type SyncResult struct {
	Account      string
	Mailboxes    []MailboxResult
	Duration     time.Duration
	TotalNew     int
	TotalSkipped int
	Error        error
}

// MailboxResult contains the results for a single mailbox
type MailboxResult struct {
	Name        string
	TotalMsgs   uint32
	NewMsgs     int
	SkippedMsgs int
	Error       error
}

// Syncer handles IMAP synchronization for an account
type Syncer struct {
	client   *Client
	maildir  *MaildirWriter
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
			key, err := s.maildir.WriteMessage(mailboxName, msg)
			if err != nil {
				fmt.Fprintf(s.output, "    Warning: failed to write message %d: %v\n", msg.Uid, err)
				result.SkippedMsgs++
				continue
			}

			// Mark as synced
			mboxState.AddSyncedUID(msg.Uid)
			s.maildir.MarkMessageSynced(mailboxName, msg.Uid, key)
			result.NewMsgs++
		}
	}

	if result.NewMsgs > 0 {
		fmt.Fprintf(s.output, "    ✓ %d new messages\n", result.NewMsgs)
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
