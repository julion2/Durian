package handler

import (
	"errors"
	"net/http"
	"net/mail"
	"os"
	"sort"

	internmail "github.com/durian-dev/durian/cli/internal/mail"
	"github.com/durian-dev/durian/cli/internal/notmuch"
	"github.com/durian-dev/durian/cli/internal/protocol"
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

// ShowMessageBody returns the full (unstripped) body of a single message by notmuch ID.
// Used for reply quoting where the conversation chain must be preserved.
func (h *Handler) ShowMessageBody(messageID string) protocol.Response {
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

// DownloadAttachment streams a raw attachment part, setting Content-Type and
// Content-Disposition headers from server-derived metadata.
func (h *Handler) DownloadAttachment(messageID string, partID int, w http.ResponseWriter) error {
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
