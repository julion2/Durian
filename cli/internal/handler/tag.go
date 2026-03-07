package handler

import (
	"log/slog"
	"strings"

	"github.com/durian-dev/durian/cli/internal/protocol"
)

// Tag handles the "tag" command.
// When useStore is true, the store is the primary write target.
// notmuch is kept in sync as a secondary (compat) layer until fully removed.
func (h *Handler) Tag(query string, tags string) protocol.Response {
	tagList := strings.Fields(tags)
	if len(tagList) == 0 {
		return protocol.FailWithMessage(protocol.ErrInvalidJSON, "no tags provided")
	}

	add, remove := splitTagOps(tagList)

	// Store-primary path: write to store first, then mirror to notmuch
	if h.useStore && h.store != nil && strings.HasPrefix(query, "thread:") {
		threadID := strings.TrimPrefix(query, "thread:")
		if err := h.store.ModifyTagsByThread(threadID, add, remove); err != nil {
			return protocol.Fail(protocol.ErrBackendError, err)
		}

		// Mirror to notmuch (compat — errors are non-fatal)
		if err := h.notmuch.Tag(query, tagList); err != nil {
			slog.Warn("notmuch tag mirror failed", "module", "HANDLER", "query", query, "err", err)
		}

		return protocol.Success()
	}

	// Legacy path: notmuch primary
	if err := h.notmuch.Tag(query, tagList); err != nil {
		return protocol.Fail(protocol.ErrBackendError, err)
	}

	// Mirror to store if available
	if h.store != nil && strings.HasPrefix(query, "thread:") {
		threadID := strings.TrimPrefix(query, "thread:")
		if err := h.store.ModifyTagsByThread(threadID, add, remove); err != nil {
			slog.Warn("store tag mirror failed", "module", "HANDLER", "thread", threadID, "err", err)
		}
	}

	return protocol.Success()
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
