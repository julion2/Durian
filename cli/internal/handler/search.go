package handler

import (
	"strings"

	"github.com/durian-dev/durian/cli/internal/mail"
	"github.com/durian-dev/durian/cli/internal/protocol"
)

// Search handles the "search" command
func (h *Handler) Search(query string, limit int) protocol.Response {
	if limit == 0 {
		limit = 50
	}

	results, err := h.notmuch.Search(query, limit)
	if err != nil {
		return protocol.Fail(protocol.ErrBackendError, err)
	}

	mails := make([]mail.Mail, len(results))
	for i, r := range results {
		mails[i] = mail.Mail{
			ThreadID:  r.Thread,
			File:      "", // Skip file lookup - use showByThread instead
			Subject:   r.Subject,
			From:      r.Authors,
			Date:      r.DateRelative,
			Timestamp: r.Timestamp,
			Tags:      strings.Join(r.Tags, ","),
		}
	}

	return protocol.SuccessWithResults(mails)
}
