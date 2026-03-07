package handler

import (
	"log/slog"
	"strings"

	"github.com/durian-dev/durian/cli/internal/protocol"
)

// Tag handles the "tag" command.
// The store is the primary write target.
// notmuch is kept in sync as a secondary (compat) layer until fully removed.
func (h *Handler) Tag(query string, tags string) protocol.Response {
	tagList := strings.Fields(tags)
	if len(tagList) == 0 {
		return protocol.FailWithMessage(protocol.ErrInvalidJSON, "no tags provided")
	}

	add, remove := splitTagOps(tagList)

	if strings.HasPrefix(query, "thread:") {
		threadID := strings.TrimPrefix(query, "thread:")
		if err := h.store.ModifyTagsByThread(threadID, add, remove); err != nil {
			return protocol.Fail(protocol.ErrBackendError, err)
		}

		// Mirror to notmuch (compat — errors are non-fatal)
		if h.notmuch != nil {
			if err := h.notmuch.Tag(query, tagList); err != nil {
				slog.Warn("notmuch tag mirror failed", "module", "HANDLER", "query", query, "err", err)
			}
		}

		return protocol.Success()
	}

	// Non-thread queries (e.g. "tag:inbox +archived"): pass through to notmuch.
	// The store only supports thread-scoped tag modifications, so arbitrary
	// queries still need notmuch. This path will be removed once the store
	// gains query-based tag support or CLI callers migrate to thread: queries.
	if h.notmuch != nil {
		slog.Warn("non-thread tag query falling back to notmuch", "module", "HANDLER", "query", query)
		if err := h.notmuch.Tag(query, tagList); err != nil {
			return protocol.Fail(protocol.ErrBackendError, err)
		}
		return protocol.Success()
	}

	return protocol.FailWithMessage(protocol.ErrBackendError, "non-thread tag queries require notmuch")
}

// splitTagOps separates a notmuch-style tag list ("+tag", "-tag") into add and remove slices.
func splitTagOps(tagList []string) (add, remove []string) {
	for _, t := range tagList {
		if strings.HasPrefix(t, "+") {
			add = append(add, strings.TrimPrefix(t, "+"))
		} else if strings.HasPrefix(t, "-") {
			remove = append(remove, strings.TrimPrefix(t, "-"))
		}
	}
	return
}
