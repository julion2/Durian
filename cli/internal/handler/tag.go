package handler

import (
	"strings"

	"github.com/durian-dev/durian/cli/internal/protocol"
)

// Tag handles the "tag" command
func (h *Handler) Tag(query string, tags string) protocol.Response {
	tagList := strings.Fields(tags)
	if len(tagList) == 0 {
		return protocol.FailWithMessage(protocol.ErrInvalidJSON, "no tags provided")
	}

	err := h.notmuch.Tag(query, tagList)
	if err != nil {
		return protocol.Fail(protocol.ErrBackendError, err)
	}

	return protocol.Success()
}
