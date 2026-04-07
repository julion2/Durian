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
			To:        r.Recipients,
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
		threads[r.Thread] = h.convertThread(r.Thread, msgs, true)
	}

	return protocol.SuccessWithResultsAndThreads(mails, threads)
}
