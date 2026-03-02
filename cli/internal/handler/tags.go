package handler

import "github.com/durian-dev/durian/cli/internal/protocol"

// ListTags returns all known tags from notmuch.
func (h *Handler) ListTags() protocol.Response {
	tags, err := h.notmuch.ListTags()
	if err != nil {
		return protocol.Fail(protocol.ErrBackendError, err)
	}
	return protocol.SuccessWithTags(tags)
}
