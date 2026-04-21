package handler

import (
	"context"
	"encoding/base64"
	"fmt"
	"io"
	"log/slog"
	"net/mail"
	"mime/quotedprintable"
	"strings"
	"sync"
	"time"

	goImap "github.com/emersion/go-imap"

	"github.com/durian-dev/durian/cli/internal/config"
	"github.com/durian-dev/durian/cli/internal/imap"
	"github.com/durian-dev/durian/cli/internal/store"
)

// FetchRequest is sent to an account watcher to break IDLE and fetch an
// attachment section from the IMAP server.
type FetchRequest struct {
	Mailbox     string    // mailbox to SELECT (e.g. "INBOX")
	UID         uint32    // message UID
	Filename    string    // primary match key for BODYSTRUCTURE walk
	ContentType string    // secondary match key
	PartIndex   int       // 1-based attachment index (store part_id) for fallback
	Writer      io.Writer // destination for streamed bytes
	Result      chan FetchResult
}

// FetchResult carries the outcome of a FetchRequest.
type FetchResult struct{ Err error }

// accountWatcher holds per-account state for the IDLE watcher goroutine.
type accountWatcher struct {
	account *config.AccountConfig
	fetchCh chan FetchRequest // buffered(1)
	syncCh  chan struct{}     // buffered(1) — signals upload-only sync for tag changes
}

// WatcherManager runs per-account IMAP IDLE watchers that trigger syncs
// and broadcast new-mail events via the EventHub.
type WatcherManager struct {
	hub         *EventHub
	store       *store.DB
	log         *slog.Logger
	locks       map[string]*sync.Mutex // per-account sync locks keyed by email
	locksMu     sync.Mutex             // protects the locks map
	watchers    map[string]*accountWatcher           // keyed by account identifier (e.g. "work")
	filterRules []config.RuleConfig                  // user-defined filter rules applied at sync time
	groups      map[string]config.GroupEntry          // contact groups for group: expansion in rules
}

// NewWatcherManager creates a WatcherManager wired to the given EventHub
// and SQLite store.
func NewWatcherManager(hub *EventHub, db *store.DB, rules []config.RuleConfig, groups map[string]config.GroupEntry) *WatcherManager {
	return &WatcherManager{
		hub:         hub,
		store:       db,
		log:         slog.Default().With("module", "WATCHER"),
		locks:       make(map[string]*sync.Mutex),
		watchers:    make(map[string]*accountWatcher),
		filterRules: rules,
		groups:      groups,
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
	// Build watchers map so FetchAttachment can route requests by account
	for _, acc := range accounts {
		key := acc.AccountIdentifier()
		aw := &accountWatcher{
			account: acc,
			fetchCh: make(chan FetchRequest, 1),
			syncCh:  make(chan struct{}, 1),
		}
		w.watchers[key] = aw
	}

	var wg sync.WaitGroup
	for _, aw := range w.watchers {
		wg.Add(1)
		go func(aw *accountWatcher) {
			defer wg.Done()
			w.watchAccount(ctx, aw)
		}(aw)
	}
	wg.Wait()
}

// watchAccount runs the IDLE reconnect loop for a single account.
// Uses the Thunderbird model: reuse the IDLE connection for sync, then
// cycle back to IDLE on the same connection. This avoids opening a second
// connection which Microsoft 365 rejects with "connection reset by peer".
func (w *WatcherManager) watchAccount(ctx context.Context, aw *accountWatcher) {
	account := aw.account
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
		initOpts := &imap.SyncOptions{Quiet: true, Mailboxes: []string{"INBOX"}, Store: w.store, FilterRules: w.filterRules, Groups: w.groups}
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
			case req := <-aw.fetchCh:
				// Break IDLE to handle attachment fetch request
				close(stopIdle)
				<-idleDone
				w.log.Debug("Attachment fetch request", "account", account.Email,
					"mailbox", req.Mailbox, "uid", req.UID, "filename", req.Filename)
				fetchErr := w.handleFetchRequest(client, req)
				req.Result <- FetchResult{Err: fetchErr}
				// Re-SELECT INBOX and resume IDLE
				newStatus, err := client.SelectMailbox("INBOX")
				if err != nil {
					w.log.Error("Re-SELECT INBOX failed after fetch, reconnecting", "account", account.Email, "err", err)
					connectionAlive = false
				} else {
					uidNext = newStatus.UidNext
				}
			case <-aw.syncCh:
				// Break IDLE to push local tag/folder changes to IMAP
				close(stopIdle)
				<-idleDone
				w.log.Info("Tag change detected, syncing flags", "account", account.Email)
				w.syncFlagsOnly(account, client)
				// Re-SELECT INBOX and resume IDLE
				newStatus, err := client.SelectMailbox("INBOX")
				if err != nil {
					w.log.Error("Re-SELECT INBOX failed after sync, reconnecting", "account", account.Email, "err", err)
					connectionAlive = false
				} else {
					uidNext = newStatus.UidNext
				}
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

// handleFetchRequest performs the IMAP FETCH for a single attachment.
// SELECT mailbox → BODYSTRUCTURE → find section → FETCH BODY[section] → stream.
func (w *WatcherManager) handleFetchRequest(client *imap.Client, req FetchRequest) error {
	if _, err := client.SelectMailbox(req.Mailbox); err != nil {
		return fmt.Errorf("select mailbox %s: %w", req.Mailbox, err)
	}

	bs, err := client.FetchBodyStructure(req.UID)
	if err != nil {
		return fmt.Errorf("fetch BODYSTRUCTURE: %w", err)
	}
	if bs == nil {
		return fmt.Errorf("nil BODYSTRUCTURE for UID %d", req.UID)
	}

	sectionPath, encoding := findAttachmentSection(bs, req.Filename, req.PartIndex)
	if sectionPath == nil {
		return fmt.Errorf("attachment %q not found in BODYSTRUCTURE", req.Filename)
	}

	w.log.Debug("Streaming attachment", "uid", req.UID, "section", sectionPath,
		"filename", req.Filename, "encoding", encoding)

	// IMAP FETCH BODY[section] returns raw transfer-encoded bytes.
	// Decode based on Content-Transfer-Encoding from BODYSTRUCTURE.
	dest := req.Writer
	switch strings.ToLower(encoding) {
	case "base64":
		pr, pw := io.Pipe()
		defer pr.Close()
		go func() {
			err := client.FetchBodySection(req.UID, sectionPath, pw)
			pw.CloseWithError(err)
		}()
		decoder := base64.NewDecoder(base64.StdEncoding, pr)
		_, err := io.Copy(dest, decoder)
		return err
	case "quoted-printable":
		pr, pw := io.Pipe()
		defer pr.Close()
		go func() {
			err := client.FetchBodySection(req.UID, sectionPath, pw)
			pw.CloseWithError(err)
		}()
		_, err := io.Copy(dest, quotedprintable.NewReader(pr))
		return err
	default:
		// 7bit, 8bit, binary — no decoding needed
		return client.FetchBodySection(req.UID, sectionPath, dest)
	}
}

// FetchAttachment implements AttachmentFetcher. Routes the request to the
// appropriate account watcher's fetchCh, breaking its IDLE to perform the fetch.
func (w *WatcherManager) FetchAttachment(ctx context.Context, account, mailbox string,
	uid uint32, filename, contentType string, partIndex int, writer io.Writer) error {

	aw, ok := w.watchers[account]
	if !ok {
		return fmt.Errorf("no watcher for account %q", account)
	}

	req := FetchRequest{
		Mailbox:     mailbox,
		UID:         uid,
		Filename:    filename,
		ContentType: contentType,
		PartIndex:   partIndex,
		Writer:      writer,
		Result:      make(chan FetchResult, 1),
	}

	select {
	case aw.fetchCh <- req:
	case <-ctx.Done():
		return ctx.Err()
	}

	select {
	case res := <-req.Result:
		return res.Err
	case <-ctx.Done():
		return ctx.Err()
	}
}

// findAttachmentSection walks the IMAP BODYSTRUCTURE tree and returns the
// section path (e.g. []int{3} or []int{2,1}) and Content-Transfer-Encoding
// for the target attachment.
//
// Uses dual matching:
//  1. Primary: match by filename (checks DispositionParams["filename"] and Params["name"])
//  2. Fallback: match by 1-based attachment index (partIndex), counting only
//     attachment-like parts in DFS order (same heuristic as the Go parser).
func findAttachmentSection(bs *goImap.BodyStructure, filename string, partIndex int) ([]int, string) {
	// Primary: filename match
	if path, enc := walkForFilename(bs, filename, nil); path != nil {
		return path, enc
	}
	// Fallback: index match (1-based)
	counter := 0
	if path, enc := walkForIndex(bs, partIndex, &counter, nil); path != nil {
		return path, enc
	}
	return nil, ""
}

// walkForFilename does a DFS looking for a leaf whose filename matches target.
func walkForFilename(bs *goImap.BodyStructure, target string, prefix []int) ([]int, string) {
	if len(bs.Parts) > 0 {
		for i, child := range bs.Parts {
			path, enc := walkForFilename(child, target, append(append([]int{}, prefix...), i+1))
			if path != nil {
				return path, enc
			}
		}
		return nil, ""
	}
	// Leaf node — check filename
	name := bs.DispositionParams["filename"]
	if name == "" {
		name = bs.Params["name"]
	}
	if strings.EqualFold(name, target) {
		return prefix, bs.Encoding
	}
	return nil, ""
}

// walkForIndex does a DFS counting attachment-like leaves. Returns the section
// path and encoding when the counter reaches partIndex.
func walkForIndex(bs *goImap.BodyStructure, partIndex int, counter *int, prefix []int) ([]int, string) {
	if len(bs.Parts) > 0 {
		for i, child := range bs.Parts {
			path, enc := walkForIndex(child, partIndex, counter, append(append([]int{}, prefix...), i+1))
			if path != nil {
				return path, enc
			}
		}
		return nil, ""
	}
	// Leaf — check if attachment-like (same heuristic as sync parser)
	if !isAttachmentLike(bs) {
		return nil, ""
	}
	*counter++
	if *counter == partIndex {
		return prefix, bs.Encoding
	}
	return nil, ""
}

// isAttachmentLike returns true if the BODYSTRUCTURE leaf looks like an
// attachment: has disposition "attachment", or has a filename and isn't text/*.
func isAttachmentLike(bs *goImap.BodyStructure) bool {
	if strings.EqualFold(bs.Disposition, "attachment") {
		return true
	}
	name := bs.DispositionParams["filename"]
	if name == "" {
		name = bs.Params["name"]
	}
	return name != "" && !strings.EqualFold(bs.MIMEType, "text")
}

// TriggerSync signals the account's watcher to break IDLE and run an
// upload-only sync (flags + folder moves). Non-blocking: if a sync is
// already pending, the signal is dropped (the pending sync will pick up
// the latest state).
func (w *WatcherManager) TriggerSync(account string) {
	aw, ok := w.watchers[account]
	if !ok {
		return
	}
	select {
	case aw.syncCh <- struct{}{}:
	default:
		// Already pending — the next sync will pick up current state
	}
}

// syncFlagsOnly runs an upload-only sync for INBOX to push local flag and
// folder move changes to the IMAP server.
func (w *WatcherManager) syncFlagsOnly(account *config.AccountConfig, client *imap.Client) {
	mu := w.accountLock(account.Email)
	mu.Lock()
	defer mu.Unlock()

	opts := &imap.SyncOptions{
		Quiet:     true,
		Mode:      imap.SyncUploadOnly,
		Mailboxes: []string{"INBOX"},
		Store:     w.store,
	}
	syncer := imap.NewSyncerWithClient(account, client, opts)

	result, err := syncer.Sync()
	if err != nil {
		w.log.Error("Upload-only sync failed", "account", account.Email, "err", err)
		return
	}
	if result.FlagsUploaded > 0 || result.TotalMoved > 0 {
		w.log.Info("Upload-only sync complete", "account", account.Email,
			"flags_uploaded", result.FlagsUploaded, "moved", result.TotalMoved)
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
	opts := &imap.SyncOptions{Quiet: true, Mailboxes: []string{"INBOX"}, Store: w.store, FilterRules: w.filterRules, Groups: w.groups}
	syncer := imap.NewSyncerWithClient(account, client, opts)

	// Run sync with timeout so a flaky server can't block the watcher forever.
	// This ensures messages are in the store (whether downloaded by us or quickSync).
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

	// Look up each new message in the SQLite store for thread/subject/from/body
	messages := make([]NewMailInfo, 0, len(envelopes))
	for uid, messageID := range envelopes {
		if messageID == "" {
			continue
		}
		w.log.Debug("UID to Message-ID mapping", "account", account.Email, "uid", uid, "message_id", messageID)
		msg, err := w.store.GetByMessageID(messageID)
		if err != nil {
			w.log.Error("Store lookup failed", "account", account.Email, "message_id", messageID, "err", err)
			continue
		}
		if msg == nil {
			w.log.Debug("Message not yet in store", "account", account.Email, "message_id", messageID)
			continue
		}
		from := msg.FromAddr
		if addr, err := mail.ParseAddress(msg.FromAddr); err == nil && addr.Name != "" {
			from = addr.Name
		}
		messages = append(messages, NewMailInfo{
			ThreadID: msg.ThreadID,
			Subject:  msg.Subject,
			From:     from,
			Snippet:  cleanSnippet(msg.BodyText, 150),
		})
		w.log.Info("New mail", "account", account.Email, "thread", msg.ThreadID, "from", from, "subject", msg.Subject)
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
