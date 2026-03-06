package store

import (
	"crypto/sha256"
	"database/sql"
	"fmt"
	"strings"
)

// cleanMessageID strips angle brackets and whitespace from a Message-ID.
func cleanMessageID(id string) string {
	id = strings.TrimSpace(id)
	id = strings.TrimPrefix(id, "<")
	id = strings.TrimSuffix(id, ">")
	return id
}

// splitReferences parses a References header into individual Message-IDs.
// References are space-separated, each wrapped in angle brackets.
func splitReferences(refs string) []string {
	refs = strings.TrimSpace(refs)
	if refs == "" {
		return nil
	}
	var result []string
	for _, part := range strings.Fields(refs) {
		cleaned := cleanMessageID(part)
		if cleaned != "" {
			result = append(result, cleaned)
		}
	}
	return result
}

// hashThreadRoot produces a 16-char hex thread ID from a root Message-ID.
func hashThreadRoot(rootMsgID string) string {
	h := sha256.Sum256([]byte(rootMsgID))
	return fmt.Sprintf("%x", h[:8])
}

// computeThreadID derives a thread ID from message headers without DB lookup.
// It picks the root of the reference chain (first in References, or In-Reply-To,
// or the message's own ID) and hashes it.
func computeThreadID(messageID, inReplyTo, references string) string {
	refs := splitReferences(references)
	var root string
	switch {
	case len(refs) > 0:
		root = refs[0]
	case inReplyTo != "":
		root = cleanMessageID(inReplyTo)
	default:
		root = cleanMessageID(messageID)
	}
	return hashThreadRoot(root)
}

// resolveThreadID determines the thread ID for a message, consulting the DB
// to join an existing thread if any referenced message is already stored.
// tx must be non-nil so batch inserts see earlier messages in the same transaction.
func resolveThreadID(tx *sql.Tx, messageID, inReplyTo, references string) (string, error) {
	// Collect all referenced message IDs
	var related []string
	for _, r := range splitReferences(references) {
		related = append(related, r)
	}
	if inReplyTo != "" {
		cleaned := cleanMessageID(inReplyTo)
		if cleaned != "" {
			related = append(related, cleaned)
		}
	}

	// Walk references and look up existing thread_id
	for _, ref := range related {
		var threadID string
		err := tx.QueryRow("SELECT thread_id FROM messages WHERE message_id = ?", ref).Scan(&threadID)
		if err == nil {
			return threadID, nil
		}
		if err != sql.ErrNoRows {
			return "", fmt.Errorf("lookup thread for ref %q: %w", ref, err)
		}
	}

	// No existing thread found — compute a new one
	return computeThreadID(messageID, inReplyTo, references), nil
}
