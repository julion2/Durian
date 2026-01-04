package imap

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/durian-dev/durian/cli/internal/debug"
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
		debug.Log("WriteMessage UID %d: ERROR - empty body provided", msg.Uid)
		return "", fmt.Errorf("message has no body")
	}

	debug.Log("WriteMessage UID %d: writing %d bytes", msg.Uid, len(body))

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

// MessageExists checks if a message with the given UID already exists
// We use a marker file to track which UIDs have been synced
func (w *MaildirWriter) MessageExists(mailboxName string, uid uint32) bool {
	markerPath := w.uidMarkerPath(mailboxName, uid)
	_, err := os.Stat(markerPath)
	return err == nil
}

// MarkMessageSynced creates a marker file for a synced message
func (w *MaildirWriter) MarkMessageSynced(mailboxName string, uid uint32, key string) error {
	markerDir := filepath.Join(w.basePath, ".durian", sanitizeMailboxName(mailboxName))
	if err := os.MkdirAll(markerDir, 0755); err != nil {
		return err
	}

	markerPath := w.uidMarkerPath(mailboxName, uid)
	return os.WriteFile(markerPath, []byte(key), 0644)
}

// GetSyncedMessageKey returns the maildir key for a synced UID
func (w *MaildirWriter) GetSyncedMessageKey(mailboxName string, uid uint32) (string, error) {
	markerPath := w.uidMarkerPath(mailboxName, uid)
	data, err := os.ReadFile(markerPath)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

// DeleteMessage removes a message from maildir by its UID
// This is called when a message was deleted or moved on the IMAP server
// Returns nil if successful or if the message doesn't exist locally
func (w *MaildirWriter) DeleteMessage(mailboxName string, uid uint32) error {
	// 1. Get the maildir key from UID marker
	key, err := w.GetSyncedMessageKey(mailboxName, uid)
	if err != nil {
		// Marker doesn't exist - message wasn't properly synced, nothing to delete
		return nil
	}

	// 2. Find and delete the actual message file using maildir API
	path := w.mailboxPath(mailboxName)
	dir := maildir.Dir(path)

	// Get the message by key and remove it
	msg, err := dir.MessageByKey(key)
	if err == nil && msg != nil {
		if removeErr := msg.Remove(); removeErr != nil {
			debug.Log("DeleteMessage: failed to remove message %s: %v", key, removeErr)
		}
	}

	// 3. Delete the UID marker file
	markerPath := w.uidMarkerPath(mailboxName, uid)
	if removeErr := os.Remove(markerPath); removeErr != nil && !os.IsNotExist(removeErr) {
		debug.Log("DeleteMessage: failed to remove marker %s: %v", markerPath, removeErr)
	}

	return nil
}

// mailboxPath returns the filesystem path for a mailbox
func (w *MaildirWriter) mailboxPath(mailboxName string) string {
	// Convert IMAP mailbox name to filesystem path
	// INBOX -> basePath/INBOX
	// Sent Items -> basePath/Sent Items (or sanitized)
	name := sanitizeMailboxName(mailboxName)
	return filepath.Join(w.basePath, name)
}

// uidMarkerPath returns the path to the UID marker file
func (w *MaildirWriter) uidMarkerPath(mailboxName string, uid uint32) string {
	name := sanitizeMailboxName(mailboxName)
	return filepath.Join(w.basePath, ".durian", name, fmt.Sprintf("%d.uid", uid))
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
