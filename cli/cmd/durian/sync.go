package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/spf13/cobra"

	"github.com/durian-dev/durian/cli/internal/config"
	"github.com/durian-dev/durian/cli/internal/imap"
)

var (
	syncDryRun    bool
	syncQuiet     bool
	syncNoNotmuch bool
	syncWatch     bool
)

var syncCmd = &cobra.Command{
	Use:   "sync [email] [mailbox]",
	Short: "Sync email via IMAP",
	Long: `Sync email from IMAP server to local Maildir.

Examples:
  # Sync all configured accounts
  durian sync

  # Sync specific account
  durian sync julian@habric.com

  # Sync specific mailbox
  durian sync julian@habric.com INBOX

  # Dry run - show what would be synced
  durian sync --dry-run

  # Watch mode - stay running with IDLE for push notifications
  durian sync --watch

  # Skip notmuch indexing
  durian sync --no-notmuch`,
	RunE: runSync,
}

func init() {
	syncCmd.Flags().BoolVar(&syncDryRun, "dry-run", false, "show what would be synced without syncing")
	syncCmd.Flags().BoolVarP(&syncQuiet, "quiet", "q", false, "suppress progress output")
	syncCmd.Flags().BoolVar(&syncNoNotmuch, "no-notmuch", false, "don't run notmuch new after sync")
	syncCmd.Flags().BoolVarP(&syncWatch, "watch", "w", false, "stay running with IDLE for push notifications")

	rootCmd.AddCommand(syncCmd)
}

func runSync(cmd *cobra.Command, args []string) error {
	// Load config
	cfg, err := config.Load(cfgFile)
	if err != nil {
		return err
	}

	// Build sync options
	options := &imap.SyncOptions{
		DryRun:    syncDryRun,
		Quiet:     syncQuiet,
		NoNotmuch: syncNoNotmuch,
	}

	// Determine which accounts to sync
	var accounts []*config.AccountConfig

	if len(args) > 0 {
		// Sync specific account
		account, err := cfg.GetAccountByEmail(args[0])
		if err != nil {
			return fmt.Errorf("account not found: %s", args[0])
		}

		if account.IMAP.Host == "" {
			return fmt.Errorf("account %s has no IMAP configuration", args[0])
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

	// Watch mode
	if syncWatch {
		return runSyncWatch(accounts, options)
	}

	// Regular sync
	results, err := imap.SyncAccounts(accounts, options)
	if err != nil {
		return err
	}

	// Print summary
	if !syncQuiet {
		printSyncSummary(results)
	}

	// Check for errors
	for _, result := range results {
		if result.Error != nil {
			return fmt.Errorf("sync failed for %s: %w", result.Account, result.Error)
		}
	}

	return nil
}

func runSyncWatch(accounts []*config.AccountConfig, options *imap.SyncOptions) error {
	fmt.Fprintf(os.Stderr, "Starting watch mode for %d account(s)...\n", len(accounts))
	fmt.Fprintf(os.Stderr, "Press Ctrl+C to stop.\n\n")

	// Setup signal handling
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		<-sigChan
		fmt.Fprintf(os.Stderr, "\nStopping watch mode...\n")
		cancel()
	}()

	// Initial sync
	_, _ = imap.SyncAccounts(accounts, options)

	// Start watching each account
	for _, account := range accounts {
		go watchAccount(ctx, account, options)
	}

	// Wait for cancellation
	<-ctx.Done()
	return nil
}

func watchAccount(ctx context.Context, account *config.AccountConfig, options *imap.SyncOptions) {
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		// Connect and authenticate
		client := imap.NewClient(account)
		if err := client.Connect(); err != nil {
			fmt.Fprintf(os.Stderr, "[%s] Connection error: %v, retrying in 30s...\n", account.Email, err)
			select {
			case <-ctx.Done():
				return
			case <-time.After(30 * time.Second):
				continue
			}
		}

		if err := client.Authenticate(); err != nil {
			fmt.Fprintf(os.Stderr, "[%s] Auth error: %v, retrying in 30s...\n", account.Email, err)
			client.Close()
			select {
			case <-ctx.Done():
				return
			case <-time.After(30 * time.Second):
				continue
			}
		}

		// Select INBOX for IDLE
		if _, err := client.SelectMailbox("INBOX"); err != nil {
			fmt.Fprintf(os.Stderr, "[%s] Select error: %v\n", account.Email, err)
			client.Close()
			continue
		}

		fmt.Fprintf(os.Stderr, "[%s] Watching for new messages...\n", account.Email)

		// Start IDLE
		stopIdle := make(chan struct{})
		updates := make(chan bool, 10)

		go func() {
			if err := client.Idle(stopIdle, updates); err != nil {
				fmt.Fprintf(os.Stderr, "[%s] IDLE error: %v\n", account.Email, err)
			}
		}()

		// Wait for updates or context cancellation
		select {
		case <-ctx.Done():
			close(stopIdle)
			client.Close()
			return
		case <-updates:
			close(stopIdle)
			client.Close()

			fmt.Fprintf(os.Stderr, "[%s] New messages detected, syncing...\n", account.Email)

			// Perform sync
			syncer := imap.NewSyncer(account, options)
			result, err := syncer.Sync()
			if err != nil {
				fmt.Fprintf(os.Stderr, "[%s] Sync error: %v\n", account.Email, err)
			} else if result.TotalNew > 0 {
				fmt.Fprintf(os.Stderr, "[%s] Synced %d new messages\n", account.Email, result.TotalNew)
			}
		}
	}
}

func printSyncSummary(results []*imap.SyncResult) {
	fmt.Fprintf(os.Stderr, "\n=== Sync Summary ===\n")

	totalNew := 0
	totalErrors := 0

	for _, result := range results {
		status := "✓"
		if result.Error != nil {
			status = "✗"
			totalErrors++
		}

		fmt.Fprintf(os.Stderr, "%s %s: %d new messages (%.1fs)\n",
			status, result.Account, result.TotalNew, result.Duration.Seconds())

		totalNew += result.TotalNew
	}

	fmt.Fprintf(os.Stderr, "\nTotal: %d new messages across %d account(s)\n", totalNew, len(results))

	if totalErrors > 0 {
		fmt.Fprintf(os.Stderr, "Errors: %d account(s) failed\n", totalErrors)
	}
}
