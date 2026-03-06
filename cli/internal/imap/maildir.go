package imap

import (
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"

	"github.com/emersion/go-imap"
	"github.com/emersion/go-maildir"
)

// MaildirWriter handles writing messages to Maildir format
type MaildirWriter struct {
	basePath string
}

// NewMaildirWriter creates a new Maildir writer
func NewMaildirWriter(basePath string) *MaildirWriter {
	return &MaildirWriter{
		basePath: basePath,
	}
}

// EnsureMailbox creates the maildir structure for a mailbox if it doesn't exist
func (w *MaildirWriter) EnsureMailbox(mailboxName string) error {
	path := w.mailboxPath(mailboxName)

	// Create the maildir directories (cur, new, tmp)
	for _, subdir := range []string{"cur", "new", "tmp"} {
		dirPath := filepath.Join(path, subdir)
		if err := os.MkdirAll(dirPath, 0755); err != nil {
			return fmt.Errorf("failed to create maildir %s: %w", dirPath, err)
		}
	}

	return nil
}

// WriteMessage writes an IMAP message to the maildir
// The body parameter contains the raw message content (already read from msg.Body)
// This is necessary because io.Reader can only be read once
func (w *MaildirWriter) WriteMessage(mailboxName string, msg *imap.Message, body []byte) (string, error) {
	if msg.Uid == 0 {
		return "", fmt.Errorf("message has no UID")
	}

	if len(body) == 0 {
		slog.Debug("Empty body provided", "module", "MAILDIR", "uid", msg.Uid)
		return "", fmt.Errorf("message has no body")
	}

	slog.Debug("Writing message", "module", "MAILDIR", "uid", msg.Uid, "bytes", len(body))

	path := w.mailboxPath(mailboxName)
	dir := maildir.Dir(path)

	// Convert IMAP flags to maildir flags
	flags := imapFlagsToMaildirFlags(msg.Flags)

	// Create a new message with flags
	maildirMsg, writer, err := dir.Create(flags)
	if err != nil {
		return "", fmt.Errorf("failed to create message: %w", err)
	}

	// Write the message content
	if _, err := writer.Write(body); err != nil {
		writer.Close()
		return "", fmt.Errorf("failed to write message: %w", err)
	}

	// Close the writer
	if err := writer.Close(); err != nil {
		return "", fmt.Errorf("failed to close message: %w", err)
	}

	return maildirMsg.Key(), nil
}

// mailboxPath returns the filesystem path for a mailbox
func (w *MaildirWriter) mailboxPath(mailboxName string) string {
	// Convert IMAP mailbox name to filesystem path
	// INBOX -> basePath/INBOX
	// Sent Items -> basePath/Sent Items (or sanitized)
	name := sanitizeMailboxName(mailboxName)
	return filepath.Join(w.basePath, name)
}

// sanitizeMailboxName makes a mailbox name safe for filesystem use
func sanitizeMailboxName(name string) string {
	// Replace path separators with dots
	name = strings.ReplaceAll(name, "/", ".")
	name = strings.ReplaceAll(name, "\\", ".")
	// Remove any other problematic characters
	name = strings.ReplaceAll(name, ":", "_")
	return name
}

// imapFlagsToMaildirFlags converts IMAP flags to Maildir flags
func imapFlagsToMaildirFlags(flags []string) []maildir.Flag {
	var result []maildir.Flag

	for _, flag := range flags {
		switch flag {
		case imap.SeenFlag:
			result = append(result, maildir.FlagSeen)
		case imap.AnsweredFlag:
			result = append(result, maildir.FlagReplied)
		case imap.FlaggedFlag:
			result = append(result, maildir.FlagFlagged)
		case imap.DeletedFlag:
			result = append(result, maildir.FlagTrashed)
		case imap.DraftFlag:
			result = append(result, maildir.FlagDraft)
		}
	}

	return result
}

// GetMailboxes returns all mailbox directories in the maildir
func (w *MaildirWriter) GetMailboxes() ([]string, error) {
	entries, err := os.ReadDir(w.basePath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}

	var mailboxes []string
	for _, entry := range entries {
		if entry.IsDir() && !strings.HasPrefix(entry.Name(), ".") {
			// Check if it's a valid maildir (has cur, new, tmp)
			curPath := filepath.Join(w.basePath, entry.Name(), "cur")
			if _, err := os.Stat(curPath); err == nil {
				mailboxes = append(mailboxes, entry.Name())
			}
		}
	}

	return mailboxes, nil
}

// BasePath returns the base maildir path
func (w *MaildirWriter) BasePath() string {
	return w.basePath
}
