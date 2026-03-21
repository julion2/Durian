package main

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"

	"github.com/durian-dev/durian/cli/internal/config"
	"github.com/durian-dev/durian/cli/internal/imap"
)

var (
	syncDryRun          bool
	syncQuiet           bool
	syncNoFlags         bool
	syncDownloadOnly    bool
	syncUploadOnly      bool
	syncBackfillHeaders bool
)

var syncCmd = &cobra.Command{
	Use:   "sync [account] [mailbox]",
	Short: "Sync email via IMAP",
	Long: `Sync email from IMAP server to local SQLite store.

By default, sync is bidirectional: messages are downloaded from the server,
and flag changes (read/unread, starred, etc.) are synchronized both ways.

The account can be specified by alias, name, or email address.

Examples:
  # Sync all configured accounts (bidirectional)
  durian sync

  # Sync specific account (by alias or email)
  durian sync gmail
  durian sync julian@habric.com

  # Sync specific mailbox
  durian sync gmail INBOX

  # Download only (no flag upload to server)
  durian sync --download-only

  # Upload only (sync local flag changes to server)
  durian sync --upload-only

  # Skip flag synchronization entirely
  durian sync --no-flags

  # Dry run - show what would be synced
  durian sync --dry-run`,
	RunE: runSync,
}

func init() {
	syncCmd.Flags().BoolVar(&syncDryRun, "dry-run", false, "show what would be synced without syncing")
	syncCmd.Flags().BoolVarP(&syncQuiet, "quiet", "q", false, "suppress progress output")
	syncCmd.Flags().BoolVar(&syncNoFlags, "no-flags", false, "skip flag synchronization")
	syncCmd.Flags().BoolVar(&syncDownloadOnly, "download-only", false, "only download from server (no flag upload)")
	syncCmd.Flags().BoolVar(&syncUploadOnly, "upload-only", false, "only upload local changes to server")
	syncCmd.Flags().BoolVar(&syncBackfillHeaders, "backfill-headers", false, "fetch and store headers for existing messages")

	rootCmd.AddCommand(syncCmd)
}

func runSync(cmd *cobra.Command, args []string) error {
	// Load config
	cfg, err := config.Load(cfgFile)
	if err != nil {
		return err
	}

	// Load filter rules (non-fatal if missing)
	rules, err := config.LoadRules("")
	if err != nil {
		fmt.Fprintf(os.Stderr, "Warning: failed to load rules: %v\n", err)
	}

	// Determine sync mode
	mode := imap.SyncBidirectional
	if syncDownloadOnly {
		mode = imap.SyncDownloadOnly
	} else if syncUploadOnly {
		mode = imap.SyncUploadOnly
	}

	// Open email store (required)
	emailDB, err := openEmailDB()
	if err != nil {
		return fmt.Errorf("failed to open email store: %w", err)
	}
	defer emailDB.Close()

	// Build sync options
	options := &imap.SyncOptions{
		DryRun:          syncDryRun,
		Quiet:           syncQuiet,
		NoFlags:         syncNoFlags,
		Mode:            mode,
		Store:           emailDB,
		FilterRules:     rules,
		BackfillHeaders: syncBackfillHeaders,
	}

	// Determine which accounts to sync
	var accounts []*config.AccountConfig

	if len(args) > 0 {
		// Sync specific account
		account, err := cfg.GetAccountByIdentifier(args[0])
		if err != nil {
			return fmt.Errorf("account not found: %s\nAvailable accounts: %s", args[0], cfg.ListAccountIdentifiers())
		}

		if account.IMAP.Host == "" {
			return fmt.Errorf("account %s has no IMAP configuration", account.Email)
		}

		accounts = append(accounts, account)

		// Check for specific mailbox
		if len(args) > 1 {
			options.Mailboxes = args[1:]
		}
	} else {
		// Sync all accounts with IMAP config
		accounts = cfg.GetAccountsWithIMAP()
		if len(accounts) == 0 {
			return fmt.Errorf("no accounts with IMAP configuration found")
		}
	}

	// Regular sync
	results, err := imap.SyncAccounts(accounts, options)
	if err != nil {
		return err
	}

	// Check for errors
	for _, result := range results {
		if result.Error != nil {
			return fmt.Errorf("sync failed for %s: %w", result.Account, result.Error)
		}
	}

	return nil
}

