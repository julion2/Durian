package handler

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"time"

	"github.com/durian-dev/durian/cli/internal/config"
	"github.com/durian-dev/durian/cli/internal/imap"
	"github.com/durian-dev/durian/cli/internal/notmuch"
)

// WatcherManager runs per-account IMAP IDLE watchers that trigger syncs
// and broadcast new-mail events via the EventHub.
type WatcherManager struct {
	hub     *EventHub
	notmuch notmuch.Client
	log     *slog.Logger
	locks   map[string]*sync.Mutex // per-account sync locks keyed by email
	locksMu sync.Mutex             // protects the locks map
}

// NewWatcherManager creates a WatcherManager wired to the given EventHub and notmuch client.
func NewWatcherManager(hub *EventHub, nm notmuch.Client) *WatcherManager {
	return &WatcherManager{
		hub:     hub,
		notmuch: nm,
		log:     slog.Default().With("module", "WATCHER"),
		locks:   make(map[string]*sync.Mutex),
	}
}

// accountLock returns the per-account mutex, creating it on first use.
func (w *WatcherManager) accountLock(email string) *sync.Mutex {
	w.locksMu.Lock()
	defer w.locksMu.Unlock()
	if _, ok := w.locks[email]; !ok {
		w.locks[email] = &sync.Mutex{}
	}
	return w.locks[email]
}

// Start spawns one IDLE watcher goroutine per account. Each watcher
// connects once, runs an initial sync on that connection, then enters
// the IDLE loop — one connection per account for the entire lifecycle.
func (w *WatcherManager) Start(ctx context.Context, accounts []*config.AccountConfig) {
	var wg sync.WaitGroup
	for _, acc := range accounts {
		wg.Add(1)
		go func(account *config.AccountConfig) {
			defer wg.Done()
			w.watchAccount(ctx, account)
		}(acc)
	}
	wg.Wait()
}

// watchAccount runs the IDLE reconnect loop for a single account.
// Uses the Thunderbird model: reuse the IDLE connection for sync, then
// cycle back to IDLE on the same connection. This avoids opening a second
// connection which Microsoft 365 rejects with "connection reset by peer".
func (w *WatcherManager) watchAccount(ctx context.Context, account *config.AccountConfig) {
	backoff := 30 * time.Second
	var lastErr string
	var sameErrCount int

	// Outer loop: reconnect on fatal errors
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		// Connect and authenticate
		client := imap.NewClient(account)
		if err := client.Connect(); err != nil {
			w.logRetry(&lastErr, &sameErrCount, &backoff, account.Email, "connection error", err)
			select {
			case <-ctx.Done():
				return
			case <-time.After(backoff):
				continue
			}
		}

		if err := client.Authenticate(); err != nil {
			w.logRetry(&lastErr, &sameErrCount, &backoff, account.Email, "auth error", err)
			client.Close()
			select {
			case <-ctx.Done():
				return
			case <-time.After(backoff):
				continue
			}
		}

		// Successful connect+auth — reset backoff
		backoff = 30 * time.Second
		lastErr = ""
		sameErrCount = 0

		// Initial sync on the watcher's connection (catch-up, no SSE notification).
		// If this kills the connection, SELECT below will fail and the
		// outer loop reconnects with 30s backoff.
		initOpts := &imap.SyncOptions{Quiet: true, Mailboxes: []string{"INBOX"}}
		initSyncer := imap.NewSyncerWithClient(account, client, initOpts)
		if _, err := initSyncer.Sync(); err != nil {
			w.log.Error("Initial sync failed", "account", account.Email, "err", err)
		}

		// Select INBOX for IDLE (sync may have left a different mailbox selected)
		status, err := client.SelectMailbox("INBOX")
		if err != nil {
			w.log.Error("Select INBOX failed after sync, reconnecting in 30s", "account", account.Email, "err", err)
			client.Close()
			select {
			case <-ctx.Done():
				return
			case <-time.After(30 * time.Second):
				continue
			}
		}
		// Track UIDNEXT so we can detect new messages even when another
		// process (e.g. GUI quickSync) already synced them to disk.
		uidNext := status.UidNext

		w.log.Info("Watching for new messages", "account", account.Email, "uidnext", uidNext)

		// Inner loop: IDLE ↔ sync cycles on the SAME connection
		connectionAlive := true
		for connectionAlive {
			stopIdle := make(chan struct{})
			updates := make(chan bool, 10)
			idleDone := make(chan struct{})

			go func() {
				defer close(idleDone)
				if err := client.Idle(stopIdle, updates); err != nil {
					w.log.Error("IDLE error", "account", account.Email, "err", err)
				}
			}()

			select {
			case <-ctx.Done():
				close(stopIdle)
				client.Close()
				return
			case <-updates:
				close(stopIdle)
				<-idleDone // wait for IDLE goroutine to exit before reusing connection
				w.log.Info("New messages detected, syncing", "account", account.Email)
				w.syncAndNotify(account, client, uidNext)
				// Re-SELECT INBOX (sync iterates all mailboxes, last selected may differ)
				newStatus, err := client.SelectMailbox("INBOX")
				if err != nil {
					w.log.Error("Re-SELECT INBOX failed, reconnecting", "account", account.Email, "err", err)
					connectionAlive = false
				} else {
					uidNext = newStatus.UidNext
				}
			case <-idleDone:
				// IDLE goroutine exited (error or connection lost) — reconnect
				connectionAlive = false
			case <-time.After(10 * time.Minute):
				close(stopIdle)
				<-idleDone
				w.log.Info("Fallback poll, syncing", "account", account.Email)
				w.syncAndNotify(account, client, uidNext)
				newStatus, err := client.SelectMailbox("INBOX")
				if err != nil {
					w.log.Error("Re-SELECT INBOX failed, reconnecting", "account", account.Email, "err", err)
					connectionAlive = false
				} else {
					uidNext = newStatus.UidNext
				}
			}
		}

		client.Close()
	}
}

// syncAndNotify syncs the account and broadcasts a NewMailEvent if new
// messages arrived. Uses UIDNEXT tracking to detect new messages reliably,
// even when another process (e.g. GUI quickSync) already downloaded them.
// It uses a per-account mutex to prevent overlapping syncs.
func (w *WatcherManager) syncAndNotify(account *config.AccountConfig, client *imap.Client, prevUidNext uint32) {
	mu := w.accountLock(account.Email)
	mu.Lock()
	defer mu.Unlock()

	// Build syncer: reuse caller's IDLE connection, only sync INBOX.
	// Iterating other mailboxes triggers rate-limiting on M365.
	opts := &imap.SyncOptions{Quiet: true, Mailboxes: []string{"INBOX"}}
	syncer := imap.NewSyncerWithClient(account, client, opts)

	// Run sync with timeout so a flaky server can't block the watcher forever.
	// This ensures messages are in notmuch (whether downloaded by us or quickSync).
	type syncOutcome struct {
		result *imap.SyncResult
		err    error
	}
	ch := make(chan syncOutcome, 1)
	go func() {
		r, e := syncer.Sync()
		ch <- syncOutcome{r, e}
	}()

	select {
	case out := <-ch:
		if out.err != nil {
			w.log.Error("Sync failed", "account", account.Email, "err", out.err)
			return
		}
	case <-time.After(2 * time.Minute):
		w.log.Error("Sync timed out after 2m", "account", account.Email)
		return
	}

	// Detect new messages via UIDNEXT: any UID >= prevUidNext is new since
	// the last IDLE cycle, regardless of whether another process synced it.
	// Fetch envelopes for UIDs in [prevUidNext, *) to get their Message-IDs.
	w.log.Debug("Searching for new UIDs", "account", account.Email, "min_uid", prevUidNext)
	newUIDs, err := client.SearchUIDRange(prevUidNext, 0)
	if err != nil {
		w.log.Error("UID search failed", "account", account.Email, "err", err)
		return
	}
	if len(newUIDs) == 0 {
		w.log.Debug("No new UIDs found", "account", account.Email, "prev_uidnext", prevUidNext)
		return
	}
	w.log.Debug("Found new UIDs", "account", account.Email, "count", len(newUIDs), "uids", newUIDs)

	envelopes, err := client.FetchEnvelopes(newUIDs)
	if err != nil {
		w.log.Error("Envelope fetch failed", "account", account.Email, "err", err)
		return
	}

	// Collect Message-IDs and query notmuch for thread/subject/from
	var idQueries []string
	for uid, messageID := range envelopes {
		if messageID != "" {
			w.log.Debug("UID to Message-ID mapping", "account", account.Email, "uid", uid, "message_id", messageID)
			idQueries = append(idQueries, fmt.Sprintf("id:%s", messageID))
		}
	}
	if len(idQueries) == 0 {
		w.log.Debug("No Message-IDs found in envelopes", "account", account.Email, "envelope_count", len(envelopes))
		return
	}

	query := strings.Join(idQueries, " OR ")
	w.log.Debug("Running notmuch query", "account", account.Email, "query", query)

	// Fetch full message bodies via notmuch show (reuses ExtractBodyContent)
	msgs, err := w.notmuch.ShowMessages(query)
	if err != nil {
		w.log.Error("Notmuch show failed", "account", account.Email, "err", err)
		return
	}
	if len(msgs) == 0 {
		w.log.Debug("Notmuch returned 0 messages for query", "account", account.Email)
		return
	}

	messages := make([]NewMailInfo, 0, len(msgs))
	for _, msg := range msgs {
		// Look up thread ID for this message
		results, err := w.notmuch.Search("id:"+msg.ID, 1)
		if err != nil || len(results) == 0 {
			w.log.Debug("Notmuch search failed or empty", "account", account.Email, "message_id", msg.ID)
			continue
		}
		r := results[0]
		text, _, _ := notmuch.ExtractBodyContent(msg.Body)
		messages = append(messages, NewMailInfo{
			ThreadID: r.Thread,
			Subject:  r.Subject,
			From:     r.Authors,
			Snippet:  cleanSnippet(text, 150),
		})
		w.log.Info("New mail", "account", account.Email, "thread", r.Thread, "from", r.Authors, "subject", r.Subject)
	}

	w.log.Info("Broadcasting new messages", "account", account.Email, "count", len(messages))
	w.hub.Broadcast(NewMailEvent{
		Account:  account.Email,
		TotalNew: len(messages),
		Messages: messages,
	})
}

// cleanSnippet transforms raw email body text into a notification-friendly preview.
// Strips quoted replies, signatures, and collapses whitespace into a single line.
func cleanSnippet(text string, maxLen int) string {
	// Cut at signature marker
	if idx := strings.Index(text, "\n-- \n"); idx >= 0 {
		text = text[:idx]
	}

	// Strip quoted lines and build clean output
	var parts []string
	for _, line := range strings.Split(text, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, ">") {
			continue
		}
		if trimmed == "" {
			continue
		}
		parts = append(parts, trimmed)
	}

	result := strings.Join(parts, " ")
	if len(result) <= maxLen {
		return result
	}

	// Truncate at word boundary
	truncated := result[:maxLen]
	if lastSpace := strings.LastIndex(truncated, " "); lastSpace > maxLen/2 {
		truncated = truncated[:lastSpace]
	}
	return truncated + "…"
}

// logRetry logs retry errors with suppression for repeated identical errors
// and advances the backoff. After 3 identical errors, logs only every 10th
// occurrence to avoid spam.
func (w *WatcherManager) logRetry(lastErr *string, count *int, backoff *time.Duration, email, kind string, err error) {
	const maxBackoff = 10 * time.Minute

	errStr := err.Error()
	if errStr == *lastErr {
		*count++
		if *count > 3 && *count%10 != 0 {
			*backoff = min(*backoff*2, maxBackoff)
			return // suppress log
		}
		w.log.Error("Retry", "account", email, "kind", kind, "err", err, "repeat", *count, "backoff", *backoff)
	} else {
		*lastErr = errStr
		*count = 1
		w.log.Error("Retry", "account", email, "kind", kind, "err", err, "backoff", *backoff)
	}
	*backoff = min(*backoff*2, maxBackoff)
}
