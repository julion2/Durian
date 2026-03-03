package handler

import (
	"context"
	"fmt"
	"log"
	"os/exec"
	"strconv"
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
	locks   map[string]*sync.Mutex // per-account sync locks keyed by email
	locksMu sync.Mutex             // protects the locks map
}

// NewWatcherManager creates a WatcherManager wired to the given EventHub and notmuch client.
func NewWatcherManager(hub *EventHub, nm notmuch.Client) *WatcherManager {
	return &WatcherManager{
		hub:     hub,
		notmuch: nm,
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
			log.Printf("WATCHER: [%s] connection error: %v, retrying in 30s", account.Email, err)
			select {
			case <-ctx.Done():
				return
			case <-time.After(30 * time.Second):
				continue
			}
		}

		if err := client.Authenticate(); err != nil {
			log.Printf("WATCHER: [%s] auth error: %v, retrying in 30s", account.Email, err)
			client.Close()
			select {
			case <-ctx.Done():
				return
			case <-time.After(30 * time.Second):
				continue
			}
		}

		// Initial sync on the watcher's connection (best-effort).
		// If this kills the connection, SELECT below will fail and the
		// outer loop reconnects with 30s backoff.
		w.syncAndNotify(account, client)

		// Select INBOX for IDLE (sync may have left a different mailbox selected)
		if _, err := client.SelectMailbox("INBOX"); err != nil {
			log.Printf("WATCHER: [%s] select INBOX failed after sync: %v, reconnecting in 30s", account.Email, err)
			client.Close()
			select {
			case <-ctx.Done():
				return
			case <-time.After(30 * time.Second):
				continue
			}
		}

		log.Printf("WATCHER: [%s] watching for new messages...", account.Email)

		// Inner loop: IDLE ↔ sync cycles on the SAME connection
		connectionAlive := true
		for connectionAlive {
			stopIdle := make(chan struct{})
			updates := make(chan bool, 10)
			idleDone := make(chan struct{})

			go func() {
				defer close(idleDone)
				if err := client.Idle(stopIdle, updates); err != nil {
					log.Printf("WATCHER: [%s] IDLE error: %v", account.Email, err)
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
				log.Printf("WATCHER: [%s] new messages detected, syncing...", account.Email)
				w.syncAndNotify(account, client)
				// Re-SELECT INBOX (sync iterates all mailboxes, last selected may differ)
				if _, err := client.SelectMailbox("INBOX"); err != nil {
					log.Printf("WATCHER: [%s] re-SELECT INBOX failed: %v, reconnecting", account.Email, err)
					connectionAlive = false
				}
			case <-idleDone:
				// IDLE goroutine exited (error or connection lost) — reconnect
				connectionAlive = false
			case <-time.After(10 * time.Minute):
				close(stopIdle)
				<-idleDone
				log.Printf("WATCHER: [%s] fallback poll, syncing...", account.Email)
				w.syncAndNotify(account, client)
				if _, err := client.SelectMailbox("INBOX"); err != nil {
					log.Printf("WATCHER: [%s] re-SELECT INBOX failed: %v, reconnecting", account.Email, err)
					connectionAlive = false
				}
			}
		}

		client.Close()
	}
}

// syncAndNotify syncs the account and broadcasts a NewMailEvent if new
// messages arrived. It uses a per-account mutex to prevent overlapping syncs.
// If client is non-nil, the syncer reuses that connection instead of opening a new one.
func (w *WatcherManager) syncAndNotify(account *config.AccountConfig, client *imap.Client) {
	mu := w.accountLock(account.Email)
	mu.Lock()
	defer mu.Unlock()

	// Capture lastmod before sync so we know exactly which messages are new.
	// notmuch count --lastmod outputs: count\tuuid\tlastmod
	var prevLastmod int64
	out, err := exec.Command("notmuch", "count", "--lastmod", "*").Output()
	if err != nil {
		log.Printf("WATCHER: [%s] failed to get lastmod: %v", account.Email, err)
		// Continue anyway — sync is more important than notifications
	} else {
		fields := strings.Split(strings.TrimSpace(string(out)), "\t")
		if len(fields) >= 3 {
			prevLastmod, _ = strconv.ParseInt(fields[2], 10, 64)
		}
	}

	// Build syncer: reuse caller's connection if provided, otherwise open a new one.
	// When reusing the IDLE connection, only sync INBOX — iterating other
	// mailboxes (SELECT Sent, Drafts, etc.) triggers rate-limiting on M365
	// and causes servers like tum.de to close the connection.
	opts := &imap.SyncOptions{Quiet: true}
	var syncer *imap.Syncer
	if client != nil {
		opts.Mailboxes = []string{"INBOX"}
		syncer = imap.NewSyncerWithClient(account, client, opts)
	} else {
		syncer = imap.NewSyncer(account, opts)
	}

	// Sync downloads new messages + runs notmuch new.
	// Run in a goroutine with a timeout so a flaky server can't block the
	// watcher forever — we need to get back to IDLE promptly.
	type syncOutcome struct {
		result *imap.SyncResult
		err    error
	}
	ch := make(chan syncOutcome, 1)
	go func() {
		r, e := syncer.Sync()
		ch <- syncOutcome{r, e}
	}()

	var result *imap.SyncResult
	select {
	case out := <-ch:
		result, err = out.result, out.err
	case <-time.After(2 * time.Minute):
		log.Printf("WATCHER: [%s] sync timed out after 2m", account.Email)
		return
	}
	if err != nil {
		log.Printf("WATCHER: [%s] sync failed: %v", account.Email, err)
		return
	}
	if result.TotalNew == 0 || prevLastmod == 0 {
		return
	}

	// Query for messages added during our sync window. Use lastmod+1 because
	// the range is inclusive and we want only what changed AFTER our snapshot.
	// No tag filter — different accounts may use different initial tags.
	query := fmt.Sprintf("lastmod:%d..", prevLastmod+1)
	results, err := w.notmuch.Search(query, 0)
	if err != nil {
		log.Printf("WATCHER: [%s] notmuch search failed: %v", account.Email, err)
		return
	}
	if len(results) == 0 {
		return
	}

	messages := make([]NewMailInfo, 0, len(results))
	for _, r := range results {
		messages = append(messages, NewMailInfo{
			ThreadID: r.Thread,
			Subject:  r.Subject,
			From:     r.Authors,
		})
	}

	w.hub.Broadcast(NewMailEvent{
		Account:  account.Email,
		TotalNew: len(messages),
		Messages: messages,
	})
}
