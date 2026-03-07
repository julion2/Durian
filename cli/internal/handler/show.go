package handler

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"net/mail"
	"os"
	"sort"
	"time"

	internmail "github.com/durian-dev/durian/cli/internal/mail"
	"github.com/durian-dev/durian/cli/internal/notmuch"
	"github.com/durian-dev/durian/cli/internal/protocol"
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

// ShowByThread handles the "show" command for a thread ID (single message - legacy)
func (h *Handler) ShowByThread(thread string) protocol.Response {
	files, err := h.notmuch.GetFiles("thread:"+thread, 1)
	if err != nil {
		return protocol.Fail(protocol.ErrBackendError, err)
	}

	if len(files) == 0 {
		return protocol.Fail(protocol.ErrNotFound, errors.New("no file found for thread"))
	}

	return h.Show(files[0])
}

// ShowThread returns all messages in a thread
func (h *Handler) ShowThread(threadID string) protocol.Response {
	if h.useStore && h.store != nil {
		return h.showThreadStore(threadID)
	}

	threadMsgs, err := h.notmuch.ShowThread(threadID)
	if err != nil {
		return protocol.Fail(protocol.ErrBackendError, err)
	}

	if len(threadMsgs) == 0 {
		return protocol.Fail(protocol.ErrNotFound, errors.New("no messages found for thread"))
	}

	thread := convertThread(threadID, threadMsgs)
	return protocol.SuccessWithThread(thread)
}

// showThreadStore implements ShowThread using the SQLite store.
func (h *Handler) showThreadStore(threadID string) protocol.Response {
	msgs, err := h.store.GetByThread(threadID)
	if err != nil {
		return protocol.Fail(protocol.ErrBackendError, err)
	}
	if len(msgs) == 0 {
		return protocol.Fail(protocol.ErrNotFound, errors.New("no messages found for thread"))
	}

	thread := h.convertStoreThread(threadID, msgs)
	return protocol.SuccessWithThread(thread)
}

// ShowMessageBody returns the full (unstripped) body of a single message by notmuch ID.
// Used for reply quoting where the conversation chain must be preserved.
func (h *Handler) ShowMessageBody(messageID string) protocol.Response {
	if h.useStore && h.store != nil {
		return h.showMessageBodyStore(messageID)
	}

	msgs, err := h.notmuch.ShowMessages("id:" + messageID)
	if err != nil {
		return protocol.Fail(protocol.ErrBackendError, err)
	}
	if len(msgs) == 0 {
		return protocol.Fail(protocol.ErrNotFound, errors.New("message not found"))
	}

	body, html, _ := notmuch.ExtractBodyContentFull(msgs[0].Body)
	return protocol.SuccessWithMessageBody(&internmail.MessageBody{
		Body: body,
		HTML: html,
	})
}

// showMessageBodyStore implements ShowMessageBody using the SQLite store.
func (h *Handler) showMessageBodyStore(messageID string) protocol.Response {
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

// convertThread converts notmuch thread messages into our ThreadContent format.
func convertThread(threadID string, threadMsgs []notmuch.ThreadMessage) *internmail.ThreadContent {
	messages := make([]internmail.MessageInfo, 0, len(threadMsgs))
	var subject string

	for _, msg := range threadMsgs {
		info := internmail.MessageInfo{
			ID:         msg.ID,
			From:       msg.Headers["From"],
			To:         msg.Headers["To"],
			CC:         msg.Headers["Cc"],
			Date:       msg.Headers["Date"],
			Timestamp:  msg.Timestamp,
			MessageID:  msg.Headers["Message-ID"],
			InReplyTo:  msg.Headers["In-Reply-To"],
			References: msg.Headers["References"],
			Tags:       msg.Tags,
		}

		if subject == "" {
			subject = msg.Headers["Subject"]
		}

		info.Body, info.HTML, info.Attachments = notmuch.ExtractBodyContent(msg.Body)
		messages = append(messages, info)
	}

	sort.Slice(messages, func(i, j int) bool {
		return messages[i].Timestamp > messages[j].Timestamp
	})

	return &internmail.ThreadContent{
		ThreadID: threadID,
		Subject:  subject,
		Messages: messages,
	}
}

// convertStoreThread converts store messages into ThreadContent format.
func (h *Handler) convertStoreThread(threadID string, msgs []*store.Message) *internmail.ThreadContent {
	messages := make([]internmail.MessageInfo, 0, len(msgs))
	var subject string

	for _, msg := range msgs {
		info := internmail.MessageInfo{
			ID:         msg.MessageID,
			From:       msg.FromAddr,
			To:         msg.ToAddrs,
			CC:         msg.CCAddrs,
			Date:       time.Unix(msg.Date, 0).Format(time.RFC1123Z),
			Timestamp:  msg.Date,
			MessageID:  msg.MessageID,
			InReplyTo:  msg.InReplyTo,
			References: msg.Refs,
			Body:       msg.BodyText,
			HTML:       notmuch.StripQuotedContent(msg.BodyHTML),
		}

		if subject == "" {
			subject = msg.Subject
		}

		// Fetch tags and attachments for each message
		if tags, err := h.store.GetMessageTags(msg.ID); err == nil {
			info.Tags = tags
		}
		if atts, err := h.store.GetAttachmentsByMessage(msg.ID); err == nil {
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
		}

		messages = append(messages, info)
	}

	// Sort newest first (same as notmuch path)
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
	if h.useStore && h.store != nil {
		return h.downloadAttachmentStore(messageID, partID, w)
	}

	msgs, err := h.notmuch.ShowMessages("id:" + messageID)
	if err != nil {
		return err
	}
	if len(msgs) == 0 {
		return errors.New("message not found")
	}

	_, _, attachments := notmuch.ExtractBodyContentFull(msgs[0].Body)
	var att *internmail.AttachmentInfo
	for i := range attachments {
		if attachments[i].PartID == partID {
			att = &attachments[i]
			break
		}
	}
	if att == nil {
		return errors.New("attachment not found")
	}

	w.Header().Set("Content-Type", att.ContentType)
	w.Header().Set("Content-Disposition", `attachment; filename="`+sanitizeFilename(att.Filename)+`"`)

	return h.notmuch.ShowRawPart(messageID, partID, w)
}

// downloadAttachmentStore implements DownloadAttachment for the store backend.
// Tries IMAP fetch first (break-IDLE pattern), falls back to notmuch if IMAP
// is unavailable or fails.
func (h *Handler) downloadAttachmentStore(messageID string, partID int, w http.ResponseWriter) error {
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

	// Try IMAP fetch (break-IDLE pattern)
	if h.fetcher != nil {
		msg, err := h.store.GetByMessageID(messageID)
		if err == nil && msg != nil && msg.UID > 0 && msg.Account != "" && msg.Mailbox != "" {
			ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
			defer cancel()

			err := h.fetcher.FetchAttachment(ctx, msg.Account, msg.Mailbox,
				msg.UID, storeAtt.Filename, storeAtt.ContentType, storeAtt.PartID, w)
			if err == nil {
				return nil
			}
			slog.Warn("IMAP attachment fetch failed, falling back to notmuch",
				"module", "HANDLER", "message_id", messageID, "err", err)
		}
	}

	// Fallback: resolve notmuch PartID by matching filename
	return h.downloadAttachmentNotmuch(messageID, storeAtt, w)
}

// downloadAttachmentNotmuch streams an attachment via notmuch's ShowRawPart.
// Used as fallback when IMAP fetch is unavailable or fails.
func (h *Handler) downloadAttachmentNotmuch(messageID string, storeAtt *store.Attachment, w http.ResponseWriter) error {
	msgs, err := h.notmuch.ShowMessages("id:" + messageID)
	if err != nil {
		return err
	}
	if len(msgs) == 0 {
		return errors.New("message not found")
	}

	_, _, nmAtts := notmuch.ExtractBodyContentFull(msgs[0].Body)
	nmPartID := -1
	for _, nmAtt := range nmAtts {
		if nmAtt.Filename == storeAtt.Filename {
			nmPartID = nmAtt.PartID
			break
		}
	}
	if nmPartID < 0 {
		return errors.New("attachment not found in message")
	}

	return h.notmuch.ShowRawPart(messageID, nmPartID, w)
}
