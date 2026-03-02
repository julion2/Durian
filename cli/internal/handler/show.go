package handler

import (
	"errors"
	"net/mail"
	"os"
	"sort"

	"github.com/durian-dev/durian/cli/internal/notmuch"
	internmail "github.com/durian-dev/durian/cli/internal/mail"
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

	// Convert notmuch messages to our format
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

		// Get subject from first message
		if subject == "" {
			subject = msg.Headers["Subject"]
		}

		// Extract body content (text/plain and text/html)
		info.Body, info.HTML, info.Attachments = notmuch.ExtractBodyContent(msg.Body)

		messages = append(messages, info)
	}

	// Sort by timestamp (newest first for email-style display)
	sort.Slice(messages, func(i, j int) bool {
		return messages[i].Timestamp > messages[j].Timestamp
	})

	thread := &internmail.ThreadContent{
		ThreadID: threadID,
		Subject:  subject,
		Messages: messages,
	}

	return protocol.SuccessWithThread(thread)
}
