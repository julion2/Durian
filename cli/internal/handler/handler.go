package handler

import (
	"github.com/durian-dev/durian/cli/internal/notmuch"
	"github.com/durian-dev/durian/cli/internal/mail"
	"github.com/durian-dev/durian/cli/internal/protocol"
)

// Handler processes commands and returns responses
type Handler struct {
	notmuch notmuch.Client
	parser  *mail.Parser
}

// New creates a new Handler with the given notmuch client
func New(nm notmuch.Client) *Handler {
	return &Handler{
		notmuch: nm,
		parser:  mail.NewParser(),
	}
}

// Handle dispatches a command to the appropriate handler method
func (h *Handler) Handle(cmd protocol.Command) protocol.Response {
	switch cmd.Cmd {
	case "search":
		return h.Search(cmd.Query, cmd.Limit)
	case "show":
		if cmd.Thread != "" {
			return h.ShowThread(cmd.Thread)
		}
		return h.Show(cmd.File)
	case "tag":
		return h.Tag(cmd.Query, cmd.Tags)
	default:
		return protocol.FailWithMessage(protocol.ErrUnknownCmd, "unknown command: "+cmd.Cmd)
	}
}
