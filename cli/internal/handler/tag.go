package handler

import (
	"log/slog"
	"strings"
	"time"

	"github.com/durian-dev/durian/cli/internal/protocol"
	"github.com/durian-dev/durian/cli/internal/tagsync"
)

// Tag handles the "tag" command.
func (h *Handler) Tag(query string, tags string) protocol.Response {
	tagList := strings.Fields(tags)
	if len(tagList) == 0 {
		return protocol.FailWithMessage(protocol.ErrInvalidJSON, "no tags provided")
	}

	add, remove := splitTagOps(tagList)

	if strings.HasPrefix(query, "thread:") {
		threadID := strings.TrimPrefix(query, "thread:")
		if err := h.store.ModifyTagsByThread(threadID, add, remove); err != nil {
			return protocol.Fail(protocol.ErrBackendError, err)
		}
		// Record in journal for tag sync (only if tag sync is configured)
		if h.tagSync != nil || h.tagSyncEnabled {
			h.journalTagChanges(threadID, add, remove)
		}
		// Trigger IMAP sync for affected accounts to push folder moves
		if h.syncTrigger != nil {
			accounts, err := h.store.GetAccountsByThread(threadID)
			if err != nil {
				slog.Debug("Failed to get accounts for sync trigger", "module", "TAG", "thread", threadID, "err", err)
			}
			for _, account := range accounts {
				h.syncTrigger.TriggerSync(account)
			}
		}
		// Push tag changes to remote sync server (best-effort)
		if h.tagSync != nil {
			go h.pushTagChanges(threadID, add, remove)
		}
		return protocol.Success()
	}

	return protocol.FailWithMessage(protocol.ErrBackendError, "only thread: queries are supported for tag modifications")
}

// journalTagChanges records tag changes in the local journal for later sync.
// Uses GetAccountsByThread instead of GetByThread to avoid dedup dropping
// multi-account entries.
func (h *Handler) journalTagChanges(threadID string, add, remove []string) {
	// Get all (message_id, account) pairs without dedup
	msgs, err := h.store.GetAllByThread(threadID)
	if err != nil || len(msgs) == 0 {
		return
	}
	now := time.Now().Unix()
	for _, msg := range msgs {
		for _, tag := range add {
			h.store.JournalTagChange(msg.MessageID, msg.Account, tag, "add", now)
		}
		for _, tag := range remove {
			h.store.JournalTagChange(msg.MessageID, msg.Account, tag, "remove", now)
		}
	}
}

// pushTagChanges sends tag changes for a thread to the remote sync server.
func (h *Handler) pushTagChanges(threadID string, add, remove []string) {
	msgs, err := h.store.GetAllByThread(threadID)
	if err != nil || len(msgs) == 0 {
		return
	}

	var changes []tagsync.TagChange
	now := time.Now().Unix()
	for _, msg := range msgs {
		for _, tag := range add {
			changes = append(changes, tagsync.TagChange{
				MessageID: msg.MessageID,
				Account:   msg.Account,
				Tag:       tag,
				Action:    "add",
				Timestamp: now,
			})
		}
		for _, tag := range remove {
			changes = append(changes, tagsync.TagChange{
				MessageID: msg.MessageID,
				Account:   msg.Account,
				Tag:       tag,
				Action:    "remove",
				Timestamp: now,
			})
		}
	}

	if err := h.tagSync.Push(changes); err != nil {
		slog.Warn("Tag sync push failed", "module", "TAGSYNC", "err", err)
	}
}

// splitTagOps separates a tag operations list ("+tag", "-tag") into add and remove slices.
func splitTagOps(tagList []string) (add, remove []string) {
	for _, t := range tagList {
		if strings.HasPrefix(t, "+") {
			add = append(add, strings.TrimPrefix(t, "+"))
		} else if strings.HasPrefix(t, "-") {
			remove = append(remove, strings.TrimPrefix(t, "-"))
		}
	}
	return
}
