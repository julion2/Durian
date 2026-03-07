package handler

import (
	"github.com/durian-dev/durian/cli/internal/contacts"
	"github.com/durian-dev/durian/cli/internal/mail"
	"github.com/durian-dev/durian/cli/internal/notmuch"
	"github.com/durian-dev/durian/cli/internal/protocol"
	"github.com/durian-dev/durian/cli/internal/store"
)

// Handler processes commands and returns responses
type Handler struct {
	notmuch  notmuch.Client
	store    *store.DB // optional SQLite store
	useStore bool      // true = read from store instead of notmuch
	parser   *mail.Parser
	contacts *contacts.DB
}

// New creates a new Handler with the given notmuch client and optional contacts DB.
func New(nm notmuch.Client, contactsDB *contacts.DB) *Handler {
	return &Handler{
		notmuch:  nm,
		parser:   mail.NewParser(),
		contacts: contactsDB,
	}
}

// NewWithStore creates a Handler that reads from the SQLite store and dual-writes
// tags to both store and notmuch (keeping notmuch in sync as fallback).
func NewWithStore(nm notmuch.Client, db *store.DB, contactsDB *contacts.DB) *Handler {
	return &Handler{
		notmuch:  nm,
		store:    db,
		useStore: true,
		parser:   mail.NewParser(),
		contacts: contactsDB,
	}
}

// Handle dispatches a command to the appropriate handler method
func (h *Handler) Handle(cmd protocol.Command) protocol.Response {
	switch cmd.Cmd {
	case "search":
		return h.Search(cmd.Query, cmd.Limit, 0)
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
