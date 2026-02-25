package imap

import (
	"os"
	"path/filepath"
	"testing"
)

func TestNewState(t *testing.T) {
	state := NewState()

	if state.Mailboxes == nil {
		t.Error("expected Mailboxes to be initialized")
	}

	if len(state.Mailboxes) != 0 {
		t.Errorf("expected empty Mailboxes, got %d", len(state.Mailboxes))
	}
}

func TestState_GetMailboxState(t *testing.T) {
	state := NewState()

	// Get state for new mailbox
	ms := state.GetMailboxState("INBOX")

	if ms == nil {
		t.Fatal("expected non-nil MailboxState")
	}

	if ms.UIDValidity != 0 {
		t.Errorf("expected UIDValidity 0, got %d", ms.UIDValidity)
	}

	if ms.LastUID != 0 {
		t.Errorf("expected LastUID 0, got %d", ms.LastUID)
	}

	if ms.SyncedUIDs == nil {
		t.Error("expected SyncedUIDs to be initialized")
	}

	// Get same mailbox again - should return same state
	ms2 := state.GetMailboxState("INBOX")
	ms2.UIDValidity = 123

	if state.GetMailboxState("INBOX").UIDValidity != 123 {
		t.Error("expected same MailboxState instance")
	}

	// Get different mailbox
	msSent := state.GetMailboxState("Sent")
	if msSent.UIDValidity != 0 {
		t.Error("expected new mailbox to have UIDValidity 0")
	}
}

func TestMailboxState_IsUIDSynced(t *testing.T) {
	ms := &MailboxState{
		SyncedUIDs: []uint32{100, 200, 300},
	}

	tests := []struct {
		uid      uint32
		expected bool
	}{
		{100, true},
		{200, true},
		{300, true},
		{150, false},
		{0, false},
		{400, false},
	}

	for _, tt := range tests {
		got := ms.IsUIDSynced(tt.uid)
		if got != tt.expected {
			t.Errorf("IsUIDSynced(%d) = %v, want %v", tt.uid, got, tt.expected)
		}
	}
}

func TestMailboxState_AddSyncedUID(t *testing.T) {
	ms := &MailboxState{
		SyncedUIDs: make([]uint32, 0),
	}

	// Add first UID
	ms.AddSyncedUID(100)
	if !ms.IsUIDSynced(100) {
		t.Error("expected UID 100 to be synced")
	}
	if ms.LastUID != 100 {
		t.Errorf("expected LastUID 100, got %d", ms.LastUID)
	}

	// Add higher UID
	ms.AddSyncedUID(200)
	if ms.LastUID != 200 {
		t.Errorf("expected LastUID 200, got %d", ms.LastUID)
	}

	// Add lower UID - LastUID should not change
	ms.AddSyncedUID(50)
	if ms.LastUID != 200 {
		t.Errorf("expected LastUID still 200, got %d", ms.LastUID)
	}

	// Add duplicate - should not add again
	lenBefore := len(ms.SyncedUIDs)
	ms.AddSyncedUID(100)
	if len(ms.SyncedUIDs) != lenBefore {
		t.Error("expected duplicate UID to not be added")
	}
}

func TestMailboxState_GetUnsyncedUIDs(t *testing.T) {
	ms := &MailboxState{
		SyncedUIDs: []uint32{100, 200, 300},
	}

	tests := []struct {
		name     string
		allUIDs  []uint32
		expected []uint32
	}{
		{
			name:     "all synced",
			allUIDs:  []uint32{100, 200, 300},
			expected: nil,
		},
		{
			name:     "none synced",
			allUIDs:  []uint32{400, 500, 600},
			expected: []uint32{400, 500, 600},
		},
		{
			name:     "mixed",
			allUIDs:  []uint32{100, 150, 200, 250, 300, 350},
			expected: []uint32{150, 250, 350},
		},
		{
			name:     "empty all",
			allUIDs:  []uint32{},
			expected: nil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := ms.GetUnsyncedUIDs(tt.allUIDs)

			if len(got) != len(tt.expected) {
				t.Errorf("got %v, want %v", got, tt.expected)
				return
			}

			for i, uid := range got {
				if uid != tt.expected[i] {
					t.Errorf("got[%d] = %d, want %d", i, uid, tt.expected[i])
				}
			}
		})
	}
}

func TestMailboxState_NeedsFullResync(t *testing.T) {
	tests := []struct {
		name           string
		currentUID     uint32
		newUID         uint32
		expectedResync bool
	}{
		{
			name:           "first sync (UIDValidity 0)",
			currentUID:     0,
			newUID:         12345,
			expectedResync: false,
		},
		{
			name:           "same UIDValidity",
			currentUID:     12345,
			newUID:         12345,
			expectedResync: false,
		},
		{
			name:           "different UIDValidity",
			currentUID:     12345,
			newUID:         67890,
			expectedResync: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ms := &MailboxState{UIDValidity: tt.currentUID}
			got := ms.NeedsFullResync(tt.newUID)
			if got != tt.expectedResync {
				t.Errorf("NeedsFullResync(%d) = %v, want %v", tt.newUID, got, tt.expectedResync)
			}
		})
	}
}

func TestMailboxState_Reset(t *testing.T) {
	ms := &MailboxState{
		UIDValidity: 12345,
		LastUID:     500,
		SyncedUIDs:  []uint32{100, 200, 300, 400, 500},
	}

	ms.Reset(67890)

	if ms.UIDValidity != 67890 {
		t.Errorf("expected UIDValidity 67890, got %d", ms.UIDValidity)
	}

	if ms.LastUID != 0 {
		t.Errorf("expected LastUID 0, got %d", ms.LastUID)
	}

	if len(ms.SyncedUIDs) != 0 {
		t.Errorf("expected empty SyncedUIDs, got %v", ms.SyncedUIDs)
	}
}

func TestStateManager_LoadSave(t *testing.T) {
	// Create temp directory for testing
	tmpDir, err := os.MkdirTemp("", "durian-test-*")
	if err != nil {
		t.Fatalf("failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	// Create state manager with custom cache dir
	sm := &StateManager{cacheDir: tmpDir}

	email := "test@example.com"

	// Load non-existent state - should return new empty state
	state, lock, err := sm.Load(email)
	if err != nil {
		t.Fatalf("Load failed: %v", err)
	}
	defer releaseLock(lock)

	if state == nil {
		t.Fatal("expected non-nil state")
	}

	if len(state.Mailboxes) != 0 {
		t.Errorf("expected empty state, got %d mailboxes", len(state.Mailboxes))
	}

	// Modify and save state
	ms := state.GetMailboxState("INBOX")
	ms.UIDValidity = 12345
	ms.AddSyncedUID(100)
	ms.AddSyncedUID(200)

	msSent := state.GetMailboxState("Sent")
	msSent.UIDValidity = 67890
	msSent.AddSyncedUID(50)

	if err := sm.Save(email, state); err != nil {
		t.Fatalf("Save failed: %v", err)
	}

	// Release lock before re-loading
	releaseLock(lock)

	// Verify file exists
	statePath := filepath.Join(tmpDir, email+"-imap-state.json")
	if _, err := os.Stat(statePath); os.IsNotExist(err) {
		t.Error("expected state file to exist")
	}

	// Load again and verify
	loaded, lock2, err := sm.Load(email)
	if err != nil {
		t.Fatalf("Load after save failed: %v", err)
	}
	defer releaseLock(lock2)

	inboxState := loaded.GetMailboxState("INBOX")
	if inboxState.UIDValidity != 12345 {
		t.Errorf("expected INBOX UIDValidity 12345, got %d", inboxState.UIDValidity)
	}

	if inboxState.LastUID != 200 {
		t.Errorf("expected INBOX LastUID 200, got %d", inboxState.LastUID)
	}

	if len(inboxState.SyncedUIDs) != 2 {
		t.Errorf("expected 2 synced UIDs, got %d", len(inboxState.SyncedUIDs))
	}

	sentState := loaded.GetMailboxState("Sent")
	if sentState.UIDValidity != 67890 {
		t.Errorf("expected Sent UIDValidity 67890, got %d", sentState.UIDValidity)
	}
}

func TestStateManager_Delete(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "durian-test-*")
	if err != nil {
		t.Fatalf("failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	sm := &StateManager{cacheDir: tmpDir}
	email := "test@example.com"

	// Create and save state
	state := NewState()
	state.GetMailboxState("INBOX").UIDValidity = 123
	if err := sm.Save(email, state); err != nil {
		t.Fatalf("Save failed: %v", err)
	}

	// Delete
	if err := sm.Delete(email); err != nil {
		t.Fatalf("Delete failed: %v", err)
	}

	// Verify file is gone
	statePath := filepath.Join(tmpDir, email+"-imap-state.json")
	if _, err := os.Stat(statePath); !os.IsNotExist(err) {
		t.Error("expected state file to be deleted")
	}

	// Delete non-existent - should not error
	if err := sm.Delete("nonexistent@example.com"); err != nil {
		t.Errorf("Delete non-existent should not error: %v", err)
	}
}
