package imap

import (
	"testing"

	"github.com/emersion/go-imap"
)

func TestFlagStateFromIMAP(t *testing.T) {
	tests := []struct {
		name     string
		flags    []string
		expected FlagState
	}{
		{
			name:     "empty flags",
			flags:    []string{},
			expected: FlagState{},
		},
		{
			name:     "seen flag",
			flags:    []string{imap.SeenFlag},
			expected: FlagState{Seen: true},
		},
		{
			name:     "all flags",
			flags:    []string{imap.SeenFlag, imap.FlaggedFlag, imap.AnsweredFlag, imap.DeletedFlag},
			expected: FlagState{Seen: true, Flagged: true, Answered: true, Deleted: true},
		},
		{
			name:     "with unknown flags",
			flags:    []string{imap.SeenFlag, "\\Custom", imap.FlaggedFlag},
			expected: FlagState{Seen: true, Flagged: true},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := FlagStateFromIMAP(tt.flags)
			if got != tt.expected {
				t.Errorf("FlagStateFromIMAP() = %+v, want %+v", got, tt.expected)
			}
		})
	}
}

func TestFlagStateFromNotmuchTags(t *testing.T) {
	tests := []struct {
		name     string
		tags     []string
		expected FlagState
	}{
		{
			name:     "no tags - defaults to seen",
			tags:     []string{},
			expected: FlagState{Seen: true},
		},
		{
			name:     "unread tag",
			tags:     []string{"unread"},
			expected: FlagState{Seen: false},
		},
		{
			name:     "flagged tag",
			tags:     []string{"flagged"},
			expected: FlagState{Seen: true, Flagged: true},
		},
		{
			name:     "unread and flagged",
			tags:     []string{"unread", "flagged"},
			expected: FlagState{Seen: false, Flagged: true},
		},
		{
			name:     "all sync tags",
			tags:     []string{"flagged", "replied", "deleted"},
			expected: FlagState{Seen: true, Flagged: true, Answered: true, Deleted: true},
		},
		{
			name:     "with non-sync tags",
			tags:     []string{"inbox", "unread", "attachment", "flagged"},
			expected: FlagState{Seen: false, Flagged: true},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := FlagStateFromNotmuchTags(tt.tags)
			if got != tt.expected {
				t.Errorf("FlagStateFromNotmuchTags() = %+v, want %+v", got, tt.expected)
			}
		})
	}
}

func TestFlagStateToIMAPFlags(t *testing.T) {
	tests := []struct {
		name     string
		state    FlagState
		expected []string
	}{
		{
			name:     "empty state",
			state:    FlagState{},
			expected: nil,
		},
		{
			name:     "seen only",
			state:    FlagState{Seen: true},
			expected: []string{imap.SeenFlag},
		},
		{
			name:     "all flags",
			state:    FlagState{Seen: true, Flagged: true, Answered: true, Deleted: true},
			expected: []string{imap.SeenFlag, imap.FlaggedFlag, imap.AnsweredFlag, imap.DeletedFlag},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := tt.state.ToIMAPFlags()
			if len(got) != len(tt.expected) {
				t.Errorf("ToIMAPFlags() len = %d, want %d", len(got), len(tt.expected))
				return
			}
			for i, flag := range got {
				if flag != tt.expected[i] {
					t.Errorf("ToIMAPFlags()[%d] = %s, want %s", i, flag, tt.expected[i])
				}
			}
		})
	}
}

func TestFlagStateToNotmuchTags(t *testing.T) {
	tests := []struct {
		name           string
		state          FlagState
		expectedAdd    []string
		expectedRemove []string
	}{
		{
			name:           "unread message",
			state:          FlagState{Seen: false},
			expectedAdd:    []string{"unread"},
			expectedRemove: []string{"flagged", "replied", "deleted"},
		},
		{
			name:           "read message",
			state:          FlagState{Seen: true},
			expectedAdd:    nil,
			expectedRemove: []string{"unread", "flagged", "replied", "deleted"},
		},
		{
			name:           "flagged unread message",
			state:          FlagState{Seen: false, Flagged: true},
			expectedAdd:    []string{"unread", "flagged"},
			expectedRemove: []string{"replied", "deleted"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			add, remove := tt.state.ToNotmuchTags()
			if !slicesEqual(add, tt.expectedAdd) {
				t.Errorf("ToNotmuchTags() add = %v, want %v", add, tt.expectedAdd)
			}
			if !slicesEqual(remove, tt.expectedRemove) {
				t.Errorf("ToNotmuchTags() remove = %v, want %v", remove, tt.expectedRemove)
			}
		})
	}
}

func TestFlagStateMerge(t *testing.T) {
	tests := []struct {
		name     string
		local    FlagState
		server   FlagState
		expected FlagState
	}{
		{
			name:     "both empty",
			local:    FlagState{},
			server:   FlagState{},
			expected: FlagState{},
		},
		{
			name:     "local seen, server not",
			local:    FlagState{Seen: true},
			server:   FlagState{},
			expected: FlagState{Seen: true},
		},
		{
			name:     "server seen, local not",
			local:    FlagState{},
			server:   FlagState{Seen: true},
			expected: FlagState{Seen: true},
		},
		{
			name:     "merge flags from both",
			local:    FlagState{Seen: true, Flagged: true},
			server:   FlagState{Answered: true},
			expected: FlagState{Seen: true, Flagged: true, Answered: true},
		},
		{
			name:     "server wins for deleted",
			local:    FlagState{Deleted: false},
			server:   FlagState{Deleted: true},
			expected: FlagState{Deleted: true},
		},
		{
			name:     "local deleted ignored",
			local:    FlagState{Deleted: true},
			server:   FlagState{Deleted: false},
			expected: FlagState{Deleted: false},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := tt.local.Merge(tt.server)
			if got != tt.expected {
				t.Errorf("Merge() = %+v, want %+v", got, tt.expected)
			}
		})
	}
}

func TestDiffFlags(t *testing.T) {
	tests := []struct {
		name           string
		local          FlagState
		server         FlagState
		expectedAdd    []string
		expectedRemove []string
	}{
		{
			name:           "no difference",
			local:          FlagState{Seen: true},
			server:         FlagState{Seen: true},
			expectedAdd:    nil,
			expectedRemove: nil,
		},
		{
			name:           "local seen, server not",
			local:          FlagState{Seen: true},
			server:         FlagState{},
			expectedAdd:    []string{imap.SeenFlag},
			expectedRemove: nil,
		},
		{
			name:           "server seen, local not",
			local:          FlagState{},
			server:         FlagState{Seen: true},
			expectedAdd:    nil,
			expectedRemove: []string{imap.SeenFlag},
		},
		{
			name:           "multiple differences",
			local:          FlagState{Seen: true, Flagged: true},
			server:         FlagState{Answered: true},
			expectedAdd:    []string{imap.SeenFlag, imap.FlaggedFlag},
			expectedRemove: []string{imap.AnsweredFlag},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			add, remove := DiffFlags(tt.local, tt.server)
			if !slicesEqual(add, tt.expectedAdd) {
				t.Errorf("DiffFlags() add = %v, want %v", add, tt.expectedAdd)
			}
			if !slicesEqual(remove, tt.expectedRemove) {
				t.Errorf("DiffFlags() remove = %v, want %v", remove, tt.expectedRemove)
			}
		})
	}
}

func TestNeedsUpload(t *testing.T) {
	tests := []struct {
		name     string
		local    FlagState
		stored   FlagState
		expected bool
	}{
		{
			name:     "no change",
			local:    FlagState{Seen: true},
			stored:   FlagState{Seen: true},
			expected: false,
		},
		{
			name:     "seen changed",
			local:    FlagState{Seen: true},
			stored:   FlagState{Seen: false},
			expected: true,
		},
		{
			name:     "flagged changed",
			local:    FlagState{Flagged: true},
			stored:   FlagState{Flagged: false},
			expected: true,
		},
		{
			name:     "deleted changed - now synced",
			local:    FlagState{Deleted: true},
			stored:   FlagState{Deleted: false},
			expected: true, // Deleted changes are now uploaded for trash workflow
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := NeedsUpload(tt.local, tt.stored)
			if got != tt.expected {
				t.Errorf("NeedsUpload() = %v, want %v", got, tt.expected)
			}
		})
	}
}

func TestNeedsDownload(t *testing.T) {
	tests := []struct {
		name     string
		server   FlagState
		stored   FlagState
		expected bool
	}{
		{
			name:     "no change",
			server:   FlagState{Seen: true},
			stored:   FlagState{Seen: true},
			expected: false,
		},
		{
			name:     "seen changed",
			server:   FlagState{Seen: true},
			stored:   FlagState{Seen: false},
			expected: true,
		},
		{
			name:     "deleted changed - included",
			server:   FlagState{Deleted: true},
			stored:   FlagState{Deleted: false},
			expected: true, // Deleted changes ARE downloaded
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := NeedsDownload(tt.server, tt.stored)
			if got != tt.expected {
				t.Errorf("NeedsDownload() = %v, want %v", got, tt.expected)
			}
		})
	}
}

// Helper function to compare slices
func slicesEqual(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
