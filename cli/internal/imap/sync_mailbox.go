package imap

import (
	"bytes"
	"fmt"
	"io"
	"log/slog"
	"net/mail"
	"sort"
	"strings"
)

// selectedHeaders are the headers stored in message_headers for rule matching.
var selectedHeaders = []string{
	"List-Id", "List-Unsubscribe", "Precedence",
	"X-Mailer", "Return-Path", "X-GitHub-Reason",
	"Authentication-Results",
}

// backfillHeaders fetches headers from the IMAP server for messages that
// are already in the store but don't have entries in message_headers yet.
func (s *Syncer) backfillHeaders(mailboxes []string) {
	fmt.Fprintf(s.output, "  Backfilling headers...\n")

	for _, mboxName := range mailboxes {
		mboxState := s.state.GetMailboxState(mboxName)
		if _, err := s.client.SelectMailbox(mboxName); err != nil {
			slog.Debug("Backfill: skip mailbox", "module", "SYNC", "mailbox", mboxName, "err", err)
			continue
		}

		// Get all synced UIDs that have a Message-ID mapping
		var uidsToFetch []uint32
		for _, uid := range mboxState.SyncedUIDs {
			messageID, ok := mboxState.GetMessageID(uid)
			if !ok || messageID == "" {
				continue
			}
			// Check if this message already has headers in the DB
			dbID, err := s.store.GetMessageDBID(messageID, s.accountName())
			if err != nil || dbID == 0 {
				continue
			}
			if has, _ := s.store.HasHeaders(dbID); has {
				continue
			}
			uidsToFetch = append(uidsToFetch, uid)
		}

		if len(uidsToFetch) == 0 {
			continue
		}

		fmt.Fprintf(s.output, "    %s: fetching headers for %d messages...\n", mboxName, len(uidsToFetch))

		// Fetch in batches
		const batchSize = 500
		stored := 0
		for i := 0; i < len(uidsToFetch); i += batchSize {
			end := i + batchSize
			if end > len(uidsToFetch) {
				end = len(uidsToFetch)
			}
			batch := uidsToFetch[i:end]

			headers, err := s.client.FetchHeadersOnly(batch)
			if err != nil {
				slog.Debug("Backfill fetch failed", "module", "SYNC", "mailbox", mboxName, "err", err)
				continue
			}

			for uid, rawHeader := range headers {
				messageID, _ := mboxState.GetMessageID(uid)
				dbID, err := s.store.GetMessageDBID(messageID, s.accountName())
				if err != nil || dbID == 0 {
					continue
				}

				parsed, err := mail.ReadMessage(bytes.NewReader(append(rawHeader, '\r', '\n')))
				if err != nil {
					continue
				}

				for _, hdrName := range selectedHeaders {
					if v := parsed.Header.Get(hdrName); v != "" {
						_ = s.store.InsertHeader(dbID, strings.ToLower(hdrName), v)
					}
				}
				stored++
			}
		}

		fmt.Fprintf(s.output, "    ✓ %d messages backfilled\n", stored)
	}
}


// syncMailbox syncs a single mailbox
func (s *Syncer) syncMailbox(mailboxName string) MailboxResult {
	result := MailboxResult{Name: mailboxName}
	slog.Debug("Syncing mailbox", "module", "SYNC", "mailbox", mailboxName)

	// Select mailbox
	status, err := s.client.SelectMailbox(mailboxName)
	if err != nil {
		result.Error = err
		return result
	}
	result.TotalMsgs = status.Messages

	// Get mailbox state
	mboxState := s.state.GetMailboxState(mailboxName)

	// Check UIDVALIDITY
	if mboxState.NeedsFullResync(status.UidValidity) {
		fmt.Fprintf(s.output, "    UIDVALIDITY changed, performing full resync\n")
		mboxState.Reset(status.UidValidity)
	}
	mboxState.UIDValidity = status.UidValidity

	// Get all UIDs
	allUIDs, err := s.client.SearchAll()
	if err != nil {
		result.Error = fmt.Errorf("failed to search messages: %w", err)
		return result
	}
	slog.Debug("Total UIDs on server", "module", "SYNC", "count", len(allUIDs))

	// Get unsynced UIDs
	unsyncedUIDs := mboxState.GetUnsyncedUIDs(allUIDs)
	slog.Debug("Unsynced UIDs", "module", "SYNC", "count", len(unsyncedUIDs))

	// Check for deleted/moved messages (UIDs that are locally synced but no longer on server)
	deletedUIDs := mboxState.GetDeletedUIDs(allUIDs)
	if len(deletedUIDs) > 0 {
		if s.options.DryRun {
			fmt.Fprintf(s.output, "    Would remove %d deleted messages\n", len(deletedUIDs))
			result.DeletedMsgs = len(deletedUIDs)
		} else {
			// When a message disappears from a folder, remove that folder's tags
			// instead of deleting the message. The message may have been moved to
			// another folder (e.g. archived) and will reappear during that folder's sync.
			tagMapping := s.getFolderTagMapping(mailboxName)

			fmt.Fprintf(s.output, "  ✗ %s: %d removed\n", mailboxName, len(deletedUIDs))
			for _, uid := range deletedUIDs {
				messageID, hasID := mboxState.GetMessageID(uid)
				if hasID && messageID != "" {
					if tagMapping != nil && len(tagMapping.AddTags) > 0 {
						// Remove the folder's tags (reverse of adding them on download)
						slog.Debug("Removing folder tags for moved message", "module", "SYNC",
							"uid", uid, "message_id", messageID, "folder", mailboxName, "tags", tagMapping.AddTags)
						if err := s.store.ModifyTagsByMessageIDAndAccount(
							messageID, s.accountName(), nil, tagMapping.AddTags); err != nil {
							slog.Warn("remove tags failed", "module", "SYNC", "uid", uid, "err", err)
						}
					} else {
						// No tag mapping for this folder — delete the message
						slog.Debug("Deleting message removed from untagged folder", "module", "SYNC",
							"uid", uid, "message_id", messageID, "folder", mailboxName)
						if err := s.store.DeleteByMessageIDAndAccount(messageID, s.accountName()); err != nil {
							slog.Warn("store delete failed", "module", "SYNC", "uid", uid, "err", err)
						}
					}
				} else {
					slog.Debug("No Message-ID for deleted UID, skipping", "module", "SYNC", "uid", uid)
				}
				mboxState.RemoveSyncedUID(uid)
				result.DeletedMsgs++
			}
		}
	}

	if len(unsyncedUIDs) == 0 {
		// Still run flag sync even if no new messages
		// Flag sync runs even in dry-run mode to show what would happen
		if !s.options.NoFlags {
			uploaded, downloaded, movedMsgs := s.syncFlags(mailboxName, mboxState, allUIDs)
			result.FlagsUploaded = uploaded
			result.FlagsDownload = downloaded
			result.MovedMsgs = movedMsgs
		}
		return result
	}

	// Apply max messages limit
	maxMessages := s.account.GetIMAPMaxMessages()
	if maxMessages > 0 && len(unsyncedUIDs) > maxMessages {
		// Sort descending (newest first) and take the most recent
		sort.Slice(unsyncedUIDs, func(i, j int) bool {
			return unsyncedUIDs[i] > unsyncedUIDs[j]
		})
		unsyncedUIDs = unsyncedUIDs[:maxMessages]
		fmt.Fprintf(s.output, "    Limited to %d most recent messages\n", maxMessages)
	}

	// Deduplication: Check if messages already exist locally (moved from another folder)
	// Fetch Message-IDs for unsynced UIDs first
	var toDownload []uint32
	if !s.options.DryRun && len(unsyncedUIDs) > 0 {
		slog.Debug("Checking for duplicates among unsynced UIDs", "module", "SYNC", "count", len(unsyncedUIDs))

		// Fetch envelopes to get Message-IDs
		envelopes, err := s.client.FetchEnvelopes(unsyncedUIDs)
		if err != nil {
			slog.Debug("Failed to fetch envelopes for dedup", "module", "SYNC", "err", err)
			// Fall back to downloading everything
			toDownload = unsyncedUIDs
		} else {
			// Store ALL Message-IDs from envelopes now, so ensureMessageIDMapping
			// in syncFlags doesn't re-fetch them from the server
			for uid, messageID := range envelopes {
				if messageID != "" {
					mboxState.SetMessageID(uid, messageID)
				}
			}

			// Get folder tag mapping for this mailbox.
			// For Gmail All Mail, skip folder mapping — labels are synced
			// via syncGmailLabels instead (the Archive mapping would
			// incorrectly strip inbox tags).
			var tagMapping *FolderTagMapping
			if !s.isGmailAllMail(mailboxName) {
				tagMapping = s.getFolderTagMapping(mailboxName)
			}

			// Check each message for duplicates
			for _, uid := range unsyncedUIDs {
				messageID, hasID := envelopes[uid]
				if !hasID || messageID == "" {
					// No Message-ID, must download
					toDownload = append(toDownload, uid)
					continue
				}

				// Check if this message already exists in the store
				exists, err := s.store.MessageExistsForAccount(messageID, s.accountName())
				if err != nil {
					slog.Debug("Failed to check message existence", "module", "SYNC", "message_id", messageID, "err", err)
					toDownload = append(toDownload, uid)
					continue
				}

				if exists {
					// Message exists! Update tags instead of downloading
					slog.Debug("Message already exists, updating tags", "module", "SYNC", "uid", uid, "message_id", messageID)

					if tagMapping != nil {
						addTags := s.filterConflictingTags(messageID, tagMapping.AddTags)
						if len(addTags) > 0 || len(tagMapping.RemoveTags) > 0 {
							if err := s.store.ModifyTagsByMessageIDAndAccount(messageID, s.accountName(), addTags, tagMapping.RemoveTags); err != nil {
								slog.Debug("Failed to update tags", "module", "SYNC", "message_id", messageID, "err", err)
							}
						}
					} else if !strings.EqualFold(mailboxName, "INBOX") {
						// Custom folder with no special-use mapping — remove inbox tag
						// since the message was moved out of INBOX
						if err := s.store.ModifyTagsByMessageIDAndAccount(messageID, s.accountName(), nil, []string{"inbox"}); err != nil {
							slog.Debug("Failed to remove inbox tag", "module", "SYNC", "message_id", messageID, "err", err)
						}
					}

					// Update mailbox and UID to reflect the message's current server folder
					if err := s.store.UpdateMailbox(messageID, s.accountName(), mailboxName, uid); err != nil {
						slog.Debug("Failed to update mailbox", "module", "SYNC", "message_id", messageID, "err", err)
					}

					// Mark as synced (we don't need to download)
					mboxState.AddSyncedUID(uid)
					mboxState.SetMessageID(uid, messageID)
					result.DeduplicatedMsgs++
				} else {
					// Message doesn't exist, need to download
					toDownload = append(toDownload, uid)
				}
			}

			if result.DeduplicatedMsgs > 0 {
				fmt.Fprintf(s.output, "  ~ %s: %d deduplicated\n", mailboxName, result.DeduplicatedMsgs)
			}
		}
	} else {
		toDownload = unsyncedUIDs
	}

	// Nothing left to download after deduplication
	if len(toDownload) == 0 {
		if result.DeduplicatedMsgs > 0 || result.DeletedMsgs > 0 {
			// Still run flag sync
			if !s.options.NoFlags {
				uploaded, downloaded, movedMsgs := s.syncFlags(mailboxName, mboxState, allUIDs)
				result.FlagsUploaded = uploaded
				result.FlagsDownload = downloaded
				result.MovedMsgs = movedMsgs
			}
		}
		return result
	}

	// Fetch remaining messages in batches
	batchSize := s.account.GetIMAPBatchSize()
	totalBatches := (len(toDownload) + batchSize - 1) / batchSize

	for i := 0; i < len(toDownload); i += batchSize {
		end := i + batchSize
		if end > len(toDownload) {
			end = len(toDownload)
		}
		batch := toDownload[i:end]
		batchNum := (i / batchSize) + 1

		fmt.Fprintf(s.output, "  ↓ %s: batch %d/%d (%d-%d)...\n",
			mailboxName, batchNum, totalBatches, i+1, end)

		if s.options.DryRun {
			result.NewMsgs += len(batch)
			continue
		}

		// Fetch messages
		messages, err := s.client.FetchMessages(batch)
		if err != nil {
			fmt.Fprintf(s.output, "    Warning: batch fetch failed: %v\n", err)
			result.SkippedMsgs += len(batch)
			continue
		}

		// Write to maildir
		for _, msg := range messages {
			// Read message body once (io.Reader can only be read once)
			var msgBody []byte
			for _, literal := range msg.Body {
				data, err := io.ReadAll(literal)
				if err == nil {
					msgBody = data
					break
				}
			}

			if len(msgBody) == 0 {
				slog.Debug("Message has no body data", "module", "SYNC", "uid", msg.Uid)
				fmt.Fprintf(s.output, "    Warning: failed to write message %d: message has no body\n", msg.Uid)
				result.SkippedMsgs++
				continue
			}

			// Insert into SQLite store with eager tags
			if err := s.storeInsertMessage(mailboxName, msg, msgBody); err != nil {
				fmt.Fprintf(s.output, "    Warning: failed to store message %d: %v\n", msg.Uid, err)
				result.SkippedMsgs++
				continue
			}

			// Mark as synced in state (no more .uid marker files needed)
			mboxState.AddSyncedUID(msg.Uid)

			// Store initial flag state
			initialFlags := FlagStateFromIMAP(msg.Flags)
			mboxState.SetMessageFlags(msg.Uid, initialFlags)

			// Extract and store Message-ID for flag sync
			messageID := extractMessageIDFromBody(msgBody)
			if messageID != "" {
				mboxState.SetMessageID(msg.Uid, messageID)
				result.NewMessageIDs = append(result.NewMessageIDs, messageID)
			}

			result.NewMsgs++
		}
	}

	if result.NewMsgs > 0 {
		fmt.Fprintf(s.output, "  ✓ %s: %d new\n", mailboxName, result.NewMsgs)
	}

	// Flag synchronization (after message download)
	// Runs in all modes except when --no-flags is set
	// The syncFlags function internally respects the sync mode and dry-run for upload/download
	if !s.options.NoFlags {
		uploaded, downloaded, movedMsgs := s.syncFlags(mailboxName, mboxState, allUIDs)
		result.FlagsUploaded = uploaded
		result.FlagsDownload = downloaded
		result.MovedMsgs = movedMsgs
	}

	return result
}

// isConnectionError checks if an error indicates a lost connection
func isConnectionError(err error) bool {
	if err == nil {
		return false
	}
	errStr := err.Error()
	return strings.Contains(errStr, "connection closed") ||
		strings.Contains(errStr, "connection reset") ||
		strings.Contains(errStr, "broken pipe") ||
		strings.Contains(errStr, "EOF") ||
		strings.Contains(errStr, "timeout") ||
		strings.Contains(errStr, "use of closed network connection")
}

// ensureMessageIDMapping builds the UID<->MessageID mapping for all UIDs on server
// This is called once per mailbox and cached in state for future syncs
func (s *Syncer) ensureMessageIDMapping(mailboxName string, mboxState *MailboxState, allUIDs []uint32) error {
	// Check which UIDs are missing from mapping
	missingUIDs := mboxState.GetMissingMappingUIDs(allUIDs)

	if len(missingUIDs) == 0 {
		slog.Debug("All UIDs already mapped", "module", "SYNC", "count", len(allUIDs))
		return nil // All mapped
	}

	slog.Debug("Fetching Message-IDs for mapping", "module", "SYNC", "missing", len(missingUIDs), "total", len(allUIDs))

	// Fetch ENVELOPEs for missing UIDs (in batches)
	envelopes, err := s.client.FetchEnvelopes(missingUIDs)
	if err != nil {
		return fmt.Errorf("failed to fetch envelopes: %w", err)
	}

	// Store mappings
	mappedCount := 0
	for uid, messageID := range envelopes {
		if messageID != "" {
			mboxState.SetMessageID(uid, messageID)
			mappedCount++
		}
	}

	slog.Debug("Mapped new UIDs", "module", "SYNC", "count", mappedCount)
	return nil
}
