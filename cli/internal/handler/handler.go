package handler

import (
	"context"
	"io"

	"github.com/durian-dev/durian/cli/internal/contacts"
	"github.com/durian-dev/durian/cli/internal/mail"
	"github.com/durian-dev/durian/cli/internal/protocol"
	"github.com/durian-dev/durian/cli/internal/store"
)

// AttachmentFetcher fetches attachment bytes directly from the IMAP server.
// Implemented by WatcherManager to break IDLE and stream BODY[section].
type AttachmentFetcher interface {
	FetchAttachment(ctx context.Context, account, mailbox string,
		uid uint32, filename, contentType string, partIndex int,
		w io.Writer) error
}

// SyncTrigger triggers an upload-only IMAP sync for an account.
// Implemented by WatcherManager to break IDLE and push local tag changes.
type SyncTrigger interface {
	TriggerSync(account string)
}

// Handler processes commands and returns responses
type Handler struct {
	store       *store.DB // SQLite store (primary read backend)
	parser      *mail.Parser
	contacts    *contacts.DB
	fetcher     AttachmentFetcher // optional IMAP attachment fetcher
	syncTrigger SyncTrigger       // optional sync trigger for tag changes
}

// New creates a Handler that reads from the SQLite store.
func New(db *store.DB, contactsDB *contacts.DB) *Handler {
	return &Handler{
		store:    db,
		parser:   mail.NewParser(),
		contacts: contactsDB,
	}
}

// SetFetcher sets the IMAP attachment fetcher (typically the WatcherManager).
func (h *Handler) SetFetcher(f AttachmentFetcher) {
	h.fetcher = f
}

// SetSyncTrigger sets the sync trigger for pushing tag changes to IMAP.
func (h *Handler) SetSyncTrigger(s SyncTrigger) {
	h.syncTrigger = s
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
