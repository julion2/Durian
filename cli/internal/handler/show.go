package handler

import (
	"errors"
	"net/mail"
	"os"

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

// ShowByThread handles the "show" command for a thread ID
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
