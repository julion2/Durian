package imap

import (
	"github.com/emersion/go-imap"
)

// FlagState represents the sync-relevant flags for a message
type FlagState struct {
	Seen      bool `json:"seen"`
	Flagged   bool `json:"flagged"`
	Answered  bool `json:"answered"`
	Deleted   bool `json:"deleted"`
	Completed bool `json:"completed"` // Outlook $Completed keyword — marks completed follow-ups
}

// Equal checks if two FlagStates are equal
func (f FlagState) Equal(other FlagState) bool {
	return f.Seen == other.Seen &&
		f.Flagged == other.Flagged &&
		f.Answered == other.Answered &&
		f.Deleted == other.Deleted &&
		f.Completed == other.Completed
}

// IsEmpty checks if all flags are false
func (f FlagState) IsEmpty() bool {
	return !f.Seen && !f.Flagged && !f.Answered && !f.Deleted && !f.Completed
}

// Merge combines two FlagStates using OR logic (except Deleted which uses server value)
func (f FlagState) Merge(server FlagState) FlagState {
	return FlagState{
		Seen:      f.Seen || server.Seen,
		Flagged:   f.Flagged || server.Flagged,
		Answered:  f.Answered || server.Answered,
		Deleted:   server.Deleted,   // Server wins for deletes
		Completed: server.Completed, // Server wins for completed (server-only concept)
	}
}

// ToIMAPFlags converts FlagState to IMAP flag strings
func (f FlagState) ToIMAPFlags() []string {
	var flags []string
	if f.Seen {
		flags = append(flags, imap.SeenFlag)
	}
	if f.Flagged {
		flags = append(flags, imap.FlaggedFlag)
	}
	if f.Answered {
		flags = append(flags, imap.AnsweredFlag)
	}
	if f.Deleted {
		flags = append(flags, imap.DeletedFlag)
	}
	return flags
}

// FlagStateFromIMAP creates a FlagState from IMAP flags
func FlagStateFromIMAP(flags []string) FlagState {
	state := FlagState{}
	for _, flag := range flags {
		switch flag {
		case imap.SeenFlag:
			state.Seen = true
		case imap.FlaggedFlag:
			state.Flagged = true
		case imap.AnsweredFlag:
			state.Answered = true
		case imap.DeletedFlag:
			state.Deleted = true
		case "$Completed":
			state.Completed = true
		}
	}
	return state
}

// FlagStateFromNotmuchTags creates a FlagState from notmuch tags
// Note: notmuch uses "unread" tag (inverse of Seen)
// Note: "deleted" notmuch tag is NOT mapped to \Deleted IMAP flag.
// \Deleted means "permanently expunge" in IMAP, while notmuch "deleted"
// means "moved to trash". Uploading \Deleted would cause servers to purge messages.
func FlagStateFromNotmuchTags(tags []string) FlagState {
	state := FlagState{
		Seen: true, // Default to seen (no unread tag)
	}

	for _, tag := range tags {
		switch tag {
		case "unread":
			state.Seen = false
		case "flagged":
			state.Flagged = true
		case "replied":
			state.Answered = true
		}
	}

	return state
}

// ToNotmuchTags converts FlagState to notmuch tags
// Returns tags to add and tags to remove
func (f FlagState) ToNotmuchTags() (add []string, remove []string) {
	if f.Seen {
		remove = append(remove, "unread")
	} else {
		add = append(add, "unread")
	}

	if f.Flagged && !f.Completed {
		add = append(add, "flagged")
	} else {
		remove = append(remove, "flagged")
	}

	if f.Answered {
		add = append(add, "replied")
	} else {
		remove = append(remove, "replied")
	}

	// Note: \Deleted IMAP flag is NOT synced to notmuch "deleted" tag.
	// \Deleted means "permanently expunge" in IMAP, durian handles
	// deletes via copy-to-trash + expunge in uploadFlagChanges instead.

	return add, remove
}

// DiffFlags returns the flags that differ between local and server
// Returns: flagsToAdd (to server), flagsToRemove (from server)
func DiffFlags(local, server FlagState) (toAdd, toRemove []string) {
	// Seen
	if local.Seen && !server.Seen {
		toAdd = append(toAdd, imap.SeenFlag)
	} else if !local.Seen && server.Seen {
		toRemove = append(toRemove, imap.SeenFlag)
	}

	// Flagged
	if local.Flagged && !server.Flagged {
		toAdd = append(toAdd, imap.FlaggedFlag)
	} else if !local.Flagged && server.Flagged {
		toRemove = append(toRemove, imap.FlaggedFlag)
	}

	// Answered
	if local.Answered && !server.Answered {
		toAdd = append(toAdd, imap.AnsweredFlag)
	} else if !local.Answered && server.Answered {
		toRemove = append(toRemove, imap.AnsweredFlag)
	}

	// Deleted - sync bidirectionally (server may auto-move to Trash)
	if local.Deleted && !server.Deleted {
		toAdd = append(toAdd, imap.DeletedFlag)
	} else if !local.Deleted && server.Deleted {
		toRemove = append(toRemove, imap.DeletedFlag)
	}

	return toAdd, toRemove
}

// NeedsUpload checks if local flags differ from stored state (needs upload to server)
func NeedsUpload(local, stored FlagState) bool {
	return local.Seen != stored.Seen ||
		local.Flagged != stored.Flagged ||
		local.Answered != stored.Answered ||
		local.Deleted != stored.Deleted
}

// NeedsDownload checks if server flags differ from stored state (needs download to local)
func NeedsDownload(server, stored FlagState) bool {
	return server.Seen != stored.Seen ||
		server.Flagged != stored.Flagged ||
		server.Answered != stored.Answered ||
		server.Deleted != stored.Deleted ||
		server.Completed != stored.Completed
}
