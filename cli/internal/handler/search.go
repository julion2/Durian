package handler

import (
	"strings"

	"github.com/durian-dev/durian/cli/internal/mail"
	"github.com/durian-dev/durian/cli/internal/protocol"
)

// Search handles the "search" command.
// enrichLimit controls thread enrichment: 0 = off, >0 = enrich up to N threads
// (search uses limit for the result list, show uses enrichLimit for bodies).
func (h *Handler) Search(query string, limit int, enrichLimit int) protocol.Response {
	if limit == 0 {
		limit = 50
	}

	if h.useStore && h.store != nil {
		return h.searchStore(query, limit, enrichLimit)
	}

	results, err := h.notmuch.Search(query, limit)
	if err != nil {
		return protocol.Fail(protocol.ErrBackendError, err)
	}

	mails := make([]mail.Mail, len(results))
	for i, r := range results {
		mails[i] = mail.Mail{
			ThreadID:  r.Thread,
			File:      "",
			Subject:   r.Subject,
			From:      r.Authors,
			Date:      r.DateRelative,
			Timestamp: r.Timestamp,
			Tags:      strings.Join(r.Tags, ","),
		}
	}

	if enrichLimit <= 0 {
		return protocol.SuccessWithResults(mails)
	}

	// Enrich with thread content via a single notmuch show call.
	// enrichLimit caps the show to only the first N threads (viewport).
	// Graceful degradation: if show fails, return results without threads.
	threadGroups, err := h.notmuch.ShowByQuery(query, enrichLimit)
	if err != nil {
		return protocol.SuccessWithResults(mails)
	}

	threads := make(map[string]*mail.ThreadContent, len(threadGroups))
	for i, r := range results {
		if i < len(threadGroups) {
			threads[r.Thread] = convertThread(r.Thread, threadGroups[i])
		}
	}

	return protocol.SuccessWithResultsAndThreads(mails, threads)
}

// searchStore implements Search using the SQLite store backend.
func (h *Handler) searchStore(query string, limit int, enrichLimit int) protocol.Response {
	results, err := h.store.Search(query, limit)
	if err != nil {
		return protocol.Fail(protocol.ErrBackendError, err)
	}

	mails := make([]mail.Mail, len(results))
	for i, r := range results {
		mails[i] = mail.Mail{
			ThreadID:  r.Thread,
			Subject:   r.Subject,
			From:      r.Authors,
			Date:      r.DateRelative,
			Timestamp: r.Timestamp,
			Tags:      strings.Join(r.Tags, ","),
		}
	}

	if enrichLimit <= 0 {
		return protocol.SuccessWithResults(mails)
	}

	// Enrich threads from store
	threads := make(map[string]*mail.ThreadContent, len(results))
	for i, r := range results {
		if i >= enrichLimit {
			break
		}
		msgs, err := h.store.GetByThread(r.Thread)
		if err != nil || len(msgs) == 0 {
			continue
		}
		threads[r.Thread] = h.convertStoreThread(r.Thread, msgs)
	}

	return protocol.SuccessWithResultsAndThreads(mails, threads)
}
