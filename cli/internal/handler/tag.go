package handler

import (
	"strings"

	"github.com/durian-dev/durian/cli/internal/protocol"
)

// Tag handles the "tag" command.
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
		return protocol.Success()
	}

	return protocol.FailWithMessage(protocol.ErrBackendError, "only thread: queries are supported for tag modifications")
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
