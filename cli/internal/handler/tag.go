package handler

import (
	"log/slog"
	"strings"

	"github.com/durian-dev/durian/cli/internal/protocol"
)

// Tag handles the "tag" command.
// When the store is present, tags are written to both notmuch and the store
// to keep them in sync (notmuch remains the fallback).
func (h *Handler) Tag(query string, tags string) protocol.Response {
	tagList := strings.Fields(tags)
	if len(tagList) == 0 {
		return protocol.FailWithMessage(protocol.ErrInvalidJSON, "no tags provided")
	}

	err := h.notmuch.Tag(query, tagList)
	if err != nil {
		return protocol.Fail(protocol.ErrBackendError, err)
	}

	// Dual-write: mirror tag changes to store for thread: queries
	if h.store != nil && strings.HasPrefix(query, "thread:") {
		threadID := strings.TrimPrefix(query, "thread:")
		add, remove := splitTagOps(tagList)
		if err := h.store.ModifyTagsByThread(threadID, add, remove); err != nil {
			slog.Warn("store tag dual-write failed", "module", "HANDLER", "thread", threadID, "err", err)
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
