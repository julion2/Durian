package imap

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/emersion/go-imap"
	"github.com/emersion/go-maildir"
)

func TestNewMaildirWriter(t *testing.T) {
	w := NewMaildirWriter("/tmp/test")

	if w.basePath != "/tmp/test" {
		t.Errorf("expected basePath /tmp/test, got %s", w.basePath)
	}
}

func TestMaildirWriter_EnsureMailbox(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "durian-maildir-test-*")
	if err != nil {
		t.Fatalf("failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	w := NewMaildirWriter(tmpDir)

	// Create INBOX maildir
	if err := w.EnsureMailbox("INBOX"); err != nil {
		t.Fatalf("EnsureMailbox failed: %v", err)
	}

	// Verify directories were created
	for _, subdir := range []string{"cur", "new", "tmp"} {
		path := filepath.Join(tmpDir, "INBOX", subdir)
		if _, err := os.Stat(path); os.IsNotExist(err) {
			t.Errorf("expected %s to exist", path)
		}
	}

	// Create nested mailbox name
	if err := w.EnsureMailbox("Folder/Subfolder"); err != nil {
		t.Fatalf("EnsureMailbox for nested failed: %v", err)
	}

	// Verify sanitized path (/ -> .)
	path := filepath.Join(tmpDir, "Folder.Subfolder", "cur")
	if _, err := os.Stat(path); os.IsNotExist(err) {
		t.Errorf("expected sanitized path %s to exist", path)
	}
}

func TestMaildirWriter_mailboxPath(t *testing.T) {
	w := NewMaildirWriter("/mail")

	tests := []struct {
		mailbox  string
		expected string
	}{
		{"INBOX", "/mail/INBOX"},
		{"Sent", "/mail/Sent"},
		{"Folder/Subfolder", "/mail/Folder.Subfolder"},
		{"Path\\With\\Backslash", "/mail/Path.With.Backslash"},
		{"Name:With:Colons", "/mail/Name_With_Colons"},
	}

	for _, tt := range tests {
		got := w.mailboxPath(tt.mailbox)
		if got != tt.expected {
			t.Errorf("mailboxPath(%q) = %q, want %q", tt.mailbox, got, tt.expected)
		}
	}
}

func TestSanitizeMailboxName(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{"INBOX", "INBOX"},
		{"Sent Items", "Sent Items"},
		{"Folder/Subfolder", "Folder.Subfolder"},
		{"Path\\With\\Backslash", "Path.With.Backslash"},
		{"Name:With:Colons", "Name_With_Colons"},
		{"Complex/Path\\Name:Test", "Complex.Path.Name_Test"},
	}

	for _, tt := range tests {
		got := sanitizeMailboxName(tt.input)
		if got != tt.expected {
			t.Errorf("sanitizeMailboxName(%q) = %q, want %q", tt.input, got, tt.expected)
		}
	}
}

func TestImapFlagsToMaildirFlags(t *testing.T) {
	tests := []struct {
		name     string
		input    []string
		expected []maildir.Flag
	}{
		{
			name:     "empty flags",
			input:    []string{},
			expected: nil,
		},
		{
			name:     "seen flag",
			input:    []string{imap.SeenFlag},
			expected: []maildir.Flag{maildir.FlagSeen},
		},
		{
			name:     "answered flag",
			input:    []string{imap.AnsweredFlag},
			expected: []maildir.Flag{maildir.FlagReplied},
		},
		{
			name:     "flagged flag",
			input:    []string{imap.FlaggedFlag},
			expected: []maildir.Flag{maildir.FlagFlagged},
		},
		{
			name:     "deleted flag",
			input:    []string{imap.DeletedFlag},
			expected: []maildir.Flag{maildir.FlagTrashed},
		},
		{
			name:     "draft flag",
			input:    []string{imap.DraftFlag},
			expected: []maildir.Flag{maildir.FlagDraft},
		},
		{
			name:     "multiple flags",
			input:    []string{imap.SeenFlag, imap.AnsweredFlag, imap.FlaggedFlag},
			expected: []maildir.Flag{maildir.FlagSeen, maildir.FlagReplied, maildir.FlagFlagged},
		},
		{
			name:     "unknown flag ignored",
			input:    []string{imap.SeenFlag, "\\Unknown", imap.DraftFlag},
			expected: []maildir.Flag{maildir.FlagSeen, maildir.FlagDraft},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := imapFlagsToMaildirFlags(tt.input)

			if len(got) != len(tt.expected) {
				t.Errorf("got %v, want %v", got, tt.expected)
				return
			}

			for i, flag := range got {
				if flag != tt.expected[i] {
					t.Errorf("got[%d] = %v, want %v", i, flag, tt.expected[i])
				}
			}
		})
	}
}

func TestMaildirWriter_UIDMarker(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "durian-maildir-test-*")
	if err != nil {
		t.Fatalf("failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	w := NewMaildirWriter(tmpDir)

	// Initially no message exists
	if w.MessageExists("INBOX", 12345) {
		t.Error("expected message to not exist initially")
	}

	// Mark as synced
	if err := w.MarkMessageSynced("INBOX", 12345, "some-maildir-key"); err != nil {
		t.Fatalf("MarkMessageSynced failed: %v", err)
	}

	// Now it should exist
	if !w.MessageExists("INBOX", 12345) {
		t.Error("expected message to exist after marking")
	}

	// Get the key back
	key, err := w.GetSyncedMessageKey("INBOX", 12345)
	if err != nil {
		t.Fatalf("GetSyncedMessageKey failed: %v", err)
	}

	if key != "some-maildir-key" {
		t.Errorf("expected key 'some-maildir-key', got %q", key)
	}

	// Different UID should not exist
	if w.MessageExists("INBOX", 99999) {
		t.Error("expected different UID to not exist")
	}

	// Different mailbox should not exist
	if w.MessageExists("Sent", 12345) {
		t.Error("expected different mailbox to not have the UID")
	}
}

func TestMaildirWriter_GetMailboxes(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "durian-maildir-test-*")
	if err != nil {
		t.Fatalf("failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	w := NewMaildirWriter(tmpDir)

	// Initially empty
	mailboxes, err := w.GetMailboxes()
	if err != nil {
		t.Fatalf("GetMailboxes failed: %v", err)
	}

	if len(mailboxes) != 0 {
		t.Errorf("expected no mailboxes, got %v", mailboxes)
	}

	// Create some mailboxes
	w.EnsureMailbox("INBOX")
	w.EnsureMailbox("Sent")
	w.EnsureMailbox("Drafts")

	// Create a non-maildir directory (no cur/new/tmp)
	os.MkdirAll(filepath.Join(tmpDir, "NotAMaildir"), 0755)

	// Create a hidden directory
	os.MkdirAll(filepath.Join(tmpDir, ".hidden", "cur"), 0755)

	mailboxes, err = w.GetMailboxes()
	if err != nil {
		t.Fatalf("GetMailboxes failed: %v", err)
	}

	if len(mailboxes) != 3 {
		t.Errorf("expected 3 mailboxes, got %v", mailboxes)
	}

	// Verify each mailbox is present
	found := make(map[string]bool)
	for _, mb := range mailboxes {
		found[mb] = true
	}

	for _, expected := range []string{"INBOX", "Sent", "Drafts"} {
		if !found[expected] {
			t.Errorf("expected mailbox %s to be found", expected)
		}
	}

	// NotAMaildir and .hidden should not be included
	if found["NotAMaildir"] {
		t.Error("NotAMaildir should not be included")
	}
	if found[".hidden"] {
		t.Error(".hidden should not be included")
	}
}

func TestMaildirWriter_BasePath(t *testing.T) {
	w := NewMaildirWriter("/some/path")

	if w.BasePath() != "/some/path" {
		t.Errorf("expected /some/path, got %s", w.BasePath())
	}
}
