package handler

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/mail"
	"os"
	"sort"
	"time"

	internmail "github.com/durian-dev/durian/cli/internal/mail"
	"github.com/durian-dev/durian/cli/internal/protocol"
	"github.com/durian-dev/durian/cli/internal/sanitize"
	"github.com/durian-dev/durian/cli/internal/store"
)

// Show handles the "show" command for a file path
func (h *Handler) Show(file string) protocol.Response {
	f, err := os.Open(file)
	if err != nil {
		return protocol.Fail(protocol.ErrFileError, err)
	}
	defer f.Close()

	msg, err := mail.ReadMessage(f)
	if err != nil {
		return protocol.Fail(protocol.ErrParseFailed, err)
	}

	content := h.parser.Parse(msg)
	return protocol.SuccessWithMail(content)
}

// ShowThread returns all messages in a thread
func (h *Handler) ShowThread(threadID string) protocol.Response {
	msgs, err := h.store.GetByThread(threadID)
	if err != nil {
		return protocol.Fail(protocol.ErrBackendError, err)
	}
	if len(msgs) == 0 {
		return protocol.Fail(protocol.ErrNotFound, errors.New("no messages found for thread"))
	}

	thread := h.convertThread(threadID, msgs, false, nil, nil)
	return protocol.SuccessWithThread(thread)
}

// ShowMessageBody returns the full (unstripped) body of a single message by Message-ID.
// Used for reply quoting where the conversation chain must be preserved.
func (h *Handler) ShowMessageBody(messageID string) protocol.Response {
	msg, err := h.store.GetByMessageID(messageID)
	if err != nil {
		return protocol.Fail(protocol.ErrBackendError, err)
	}
	if msg == nil {
		return protocol.Fail(protocol.ErrNotFound, errors.New("message not found"))
	}

	return protocol.SuccessWithMessageBody(&internmail.MessageBody{
		Body: msg.BodyText,
		HTML: msg.BodyHTML,
	})
}

// convertThread converts store messages into ThreadContent format, sorted
// newest-first. When light=true, HTML and reply headers (InReplyTo,
// References) are omitted — used by search enrichment to keep response
// size small; the full thread is loaded on demand via /threads/{id}.
//
// When tagMap/attMap are provided, tags and attachments are looked up from
// the pre-fetched maps instead of querying per message (batch optimization).
func (h *Handler) convertThread(threadID string, msgs []*store.Message, light bool, tagMap map[int64][]string, attMap map[int64][]store.Attachment) *internmail.ThreadContent {
	messages := make([]internmail.MessageInfo, 0, len(msgs))
	var subject string

	for _, msg := range msgs {
		info := internmail.MessageInfo{
			ID:        msg.MessageID,
			From:      msg.FromAddr,
			To:        msg.ToAddrs,
			CC:        msg.CCAddrs,
			Date:      time.Unix(msg.Date, 0).Format(time.RFC1123Z),
			Timestamp: msg.Date,
			MessageID: msg.MessageID,
			Body:      msg.BodyText,
		}
		if !light {
			info.InReplyTo = msg.InReplyTo
			info.References = msg.Refs
			info.HTML = sanitize.StripQuotedContent(msg.BodyHTML)
		}

		if subject == "" {
			subject = msg.Subject
		}

		// Use pre-fetched maps when available, otherwise query per message
		if tagMap != nil {
			info.Tags = tagMap[msg.ID]
		} else if tags, err := h.store.GetMessageTags(msg.ID); err == nil {
			info.Tags = tags
		}

		var atts []store.Attachment
		if attMap != nil {
			atts = attMap[msg.ID]
		} else {
			atts, _ = h.store.GetAttachmentsByMessage(msg.ID)
		}
		for _, a := range atts {
			info.Attachments = append(info.Attachments, internmail.AttachmentInfo{
				PartID:      a.PartID,
				Filename:    a.Filename,
				ContentType: a.ContentType,
				Size:        a.Size,
				Disposition: a.Disposition,
				ContentID:   a.ContentID,
			})
		}

		messages = append(messages, info)
	}

	// Sort newest first
	sort.Slice(messages, func(i, j int) bool {
		return messages[i].Timestamp > messages[j].Timestamp
	})

	return &internmail.ThreadContent{
		ThreadID: threadID,
		Subject:  subject,
		Messages: messages,
	}
}

// DownloadAttachment streams a raw attachment part, setting Content-Type and
// Content-Disposition headers from server-derived metadata.
func (h *Handler) DownloadAttachment(messageID string, partID int, w http.ResponseWriter) error {
	// Get attachment metadata from store
	storeAtts, err := h.store.GetAttachmentsByMessageID(messageID)
	if err != nil {
		return err
	}
	var storeAtt *store.Attachment
	for i := range storeAtts {
		if storeAtts[i].PartID == partID {
			storeAtt = &storeAtts[i]
			break
		}
	}
	if storeAtt == nil {
		return errors.New("attachment not found")
	}

	// Set HTTP headers before streaming body
	w.Header().Set("Content-Type", storeAtt.ContentType)
	w.Header().Set("Content-Disposition", `attachment; filename="`+sanitizeFilename(storeAtt.Filename)+`"`)

	// Fetch via IMAP (break-IDLE pattern)
	if h.fetcher == nil {
		return errors.New("no attachment fetcher available")
	}

	msg, err := h.store.GetByMessageID(messageID)
	if err != nil {
		return fmt.Errorf("lookup message: %w", err)
	}
	if msg == nil || msg.UID == 0 || msg.Account == "" || msg.Mailbox == "" {
		return errors.New("message missing IMAP metadata for attachment fetch")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	return h.fetcher.FetchAttachment(ctx, msg.Account, msg.Mailbox,
		msg.UID, storeAtt.Filename, storeAtt.ContentType, storeAtt.PartID, w)
}
