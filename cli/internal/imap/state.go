package imap

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"github.com/durian-dev/durian/cli/internal/config"
)

// State tracks sync state for an account
type State struct {
	Mailboxes map[string]*MailboxState `json:"mailboxes"`
}

// MailboxState tracks sync state for a mailbox
type MailboxState struct {
	UIDValidity uint32   `json:"uid_validity"`
	LastUID     uint32   `json:"last_uid"`
	SyncedUIDs  []uint32 `json:"synced_uids"`
}

// NewState creates a new empty state
func NewState() *State {
	return &State{
		Mailboxes: make(map[string]*MailboxState),
	}
}

// GetMailboxState returns the state for a mailbox, creating it if needed
func (s *State) GetMailboxState(mailbox string) *MailboxState {
	if s.Mailboxes == nil {
		s.Mailboxes = make(map[string]*MailboxState)
	}

	if _, ok := s.Mailboxes[mailbox]; !ok {
		s.Mailboxes[mailbox] = &MailboxState{
			SyncedUIDs: make([]uint32, 0),
		}
	}

	return s.Mailboxes[mailbox]
}

// IsUIDSynced checks if a UID has been synced
func (ms *MailboxState) IsUIDSynced(uid uint32) bool {
	for _, u := range ms.SyncedUIDs {
		if u == uid {
			return true
		}
	}
	return false
}

// AddSyncedUID marks a UID as synced
func (ms *MailboxState) AddSyncedUID(uid uint32) {
	if !ms.IsUIDSynced(uid) {
		ms.SyncedUIDs = append(ms.SyncedUIDs, uid)
		if uid > ms.LastUID {
			ms.LastUID = uid
		}
	}
}

// GetUnsyncedUIDs returns UIDs that haven't been synced yet
func (ms *MailboxState) GetUnsyncedUIDs(allUIDs []uint32) []uint32 {
	syncedSet := make(map[uint32]bool)
	for _, uid := range ms.SyncedUIDs {
		syncedSet[uid] = true
	}

	var unsynced []uint32
	for _, uid := range allUIDs {
		if !syncedSet[uid] {
			unsynced = append(unsynced, uid)
		}
	}

	return unsynced
}

// NeedsFullResync returns true if UIDVALIDITY changed
func (ms *MailboxState) NeedsFullResync(newUIDValidity uint32) bool {
	return ms.UIDValidity != 0 && ms.UIDValidity != newUIDValidity
}

// Reset clears the mailbox state for a full resync
func (ms *MailboxState) Reset(uidValidity uint32) {
	ms.UIDValidity = uidValidity
	ms.LastUID = 0
	ms.SyncedUIDs = make([]uint32, 0)
}

// StateManager handles loading and saving sync state
type StateManager struct {
	cacheDir string
}

// NewStateManager creates a new state manager
func NewStateManager() *StateManager {
	// Use XDG cache dir or fallback to ~/.cache/durian
	cacheDir := os.Getenv("XDG_CACHE_HOME")
	if cacheDir == "" {
		home, _ := os.UserHomeDir()
		cacheDir = filepath.Join(home, ".cache")
	}

	return &StateManager{
		cacheDir: filepath.Join(cacheDir, "durian"),
	}
}

// statePath returns the path to the state file for an account
func (sm *StateManager) statePath(email string) string {
	return filepath.Join(sm.cacheDir, fmt.Sprintf("%s-imap-state.json", email))
}

// Load loads the sync state for an account
func (sm *StateManager) Load(email string) (*State, error) {
	path := sm.statePath(email)

	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return NewState(), nil
		}
		return nil, fmt.Errorf("failed to read state file: %w", err)
	}

	var state State
	if err := json.Unmarshal(data, &state); err != nil {
		return nil, fmt.Errorf("failed to parse state file: %w", err)
	}

	return &state, nil
}

// Save saves the sync state for an account
func (sm *StateManager) Save(email string, state *State) error {
	if err := os.MkdirAll(sm.cacheDir, 0755); err != nil {
		return fmt.Errorf("failed to create cache dir: %w", err)
	}

	path := sm.statePath(email)

	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to marshal state: %w", err)
	}

	if err := os.WriteFile(path, data, 0644); err != nil {
		return fmt.Errorf("failed to write state file: %w", err)
	}

	return nil
}

// Delete removes the state file for an account
func (sm *StateManager) Delete(email string) error {
	path := sm.statePath(email)
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// ExpandPath expands ~ in path to home directory
func ExpandPath(path string) string {
	return config.ExpandPath(path)
}
