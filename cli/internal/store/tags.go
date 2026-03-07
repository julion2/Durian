package store

import "fmt"

// AddTag adds a tag to a message. No-op if the tag already exists.
func (d *DB) AddTag(messageDBID int64, tag string) error {
	_, err := d.db.Exec(
		"INSERT OR IGNORE INTO tags (message_id, tag) VALUES (?, ?)",
		messageDBID, tag)
	if err != nil {
		return fmt.Errorf("add tag: %w", err)
	}
	return nil
}

// RemoveTag removes a tag from a message.
func (d *DB) RemoveTag(messageDBID int64, tag string) error {
	_, err := d.db.Exec(
		"DELETE FROM tags WHERE message_id = ? AND tag = ?",
		messageDBID, tag)
	if err != nil {
		return fmt.Errorf("remove tag: %w", err)
	}
	return nil
}

// TagThread adds a tag to all messages in a thread.
func (d *DB) TagThread(threadID, tag string) error {
	_, err := d.db.Exec(`
		INSERT OR IGNORE INTO tags (message_id, tag)
		SELECT id, ? FROM messages WHERE thread_id = ?`,
		tag, threadID)
	if err != nil {
		return fmt.Errorf("tag thread: %w", err)
	}
	return nil
}

// UntagThread removes a tag from all messages in a thread.
func (d *DB) UntagThread(threadID, tag string) error {
	_, err := d.db.Exec(`
		DELETE FROM tags WHERE tag = ? AND message_id IN (
			SELECT id FROM messages WHERE thread_id = ?
		)`, tag, threadID)
	if err != nil {
		return fmt.Errorf("untag thread: %w", err)
	}
	return nil
}

// ModifyTagsByThread atomically adds and removes tags for all messages in a thread.
func (d *DB) ModifyTagsByThread(threadID string, addTags, removeTags []string) error {
	tx, err := d.db.Begin()
	if err != nil {
		return fmt.Errorf("begin transaction: %w", err)
	}
	defer tx.Rollback()

	for _, tag := range addTags {
		_, err := tx.Exec(`
			INSERT OR IGNORE INTO tags (message_id, tag)
			SELECT id, ? FROM messages WHERE thread_id = ?`,
			tag, threadID)
		if err != nil {
			return fmt.Errorf("add tag %q: %w", tag, err)
		}
	}

	for _, tag := range removeTags {
		_, err := tx.Exec(`
			DELETE FROM tags WHERE tag = ? AND message_id IN (
				SELECT id FROM messages WHERE thread_id = ?
			)`, tag, threadID)
		if err != nil {
			return fmt.Errorf("remove tag %q: %w", tag, err)
		}
	}

	return tx.Commit()
}

// GetMessageTags returns all tags for a message.
func (d *DB) GetMessageTags(messageDBID int64) ([]string, error) {
	rows, err := d.db.Query(
		"SELECT tag FROM tags WHERE message_id = ? ORDER BY tag", messageDBID)
	if err != nil {
		return nil, fmt.Errorf("get tags: %w", err)
	}
	defer rows.Close()

	var tags []string
	for rows.Next() {
		var tag string
		if err := rows.Scan(&tag); err != nil {
			return nil, fmt.Errorf("scan tag: %w", err)
		}
		tags = append(tags, tag)
	}
	return tags, rows.Err()
}

// ListTags returns all distinct tags in the database.
func (d *DB) ListTags() ([]string, error) {
	rows, err := d.db.Query("SELECT DISTINCT tag FROM tags ORDER BY tag")
	if err != nil {
		return nil, fmt.Errorf("list tags: %w", err)
	}
	defer rows.Close()

	var tags []string
	for rows.Next() {
		var tag string
		if err := rows.Scan(&tag); err != nil {
			return nil, fmt.Errorf("scan tag: %w", err)
		}
		tags = append(tags, tag)
	}
	return tags, rows.Err()
}

// ModifyTagsByMessageID adds and removes tags for a message identified by its
// RFC822 Message-ID header. No-op if the message is not in the store.
func (d *DB) ModifyTagsByMessageID(messageID string, addTags, removeTags []string) error {
	tx, err := d.db.Begin()
	if err != nil {
		return fmt.Errorf("begin transaction: %w", err)
	}
	defer tx.Rollback()

	var dbID int64
	err = tx.QueryRow("SELECT id FROM messages WHERE message_id = ?", messageID).Scan(&dbID)
	if err != nil {
		return nil // message not in store — no-op
	}

	for _, tag := range addTags {
		if _, err := tx.Exec(
			"INSERT OR IGNORE INTO tags (message_id, tag) VALUES (?, ?)",
			dbID, tag); err != nil {
			return fmt.Errorf("add tag %q: %w", tag, err)
		}
	}

	for _, tag := range removeTags {
		if _, err := tx.Exec(
			"DELETE FROM tags WHERE message_id = ? AND tag = ?",
			dbID, tag); err != nil {
			return fmt.Errorf("remove tag %q: %w", tag, err)
		}
	}

	return tx.Commit()
}

// GetTagsByMessageID returns all tags for a message identified by its
// RFC822 Message-ID header. Returns nil if the message is not in the store.
func (d *DB) GetTagsByMessageID(messageID string) ([]string, error) {
	rows, err := d.db.Query(`
		SELECT t.tag FROM tags t
		JOIN messages m ON m.id = t.message_id
		WHERE m.message_id = ?
		ORDER BY t.tag`, messageID)
	if err != nil {
		return nil, fmt.Errorf("get tags by message id: %w", err)
	}
	defer rows.Close()

	var tags []string
	for rows.Next() {
		var tag string
		if err := rows.Scan(&tag); err != nil {
			return nil, fmt.Errorf("scan tag: %w", err)
		}
		tags = append(tags, tag)
	}
	return tags, rows.Err()
}

// GetAllMessagesWithTags returns a map of message_id → tags for all messages
// in a given mailbox. Used for IMAP flag synchronization.
func (d *DB) GetAllMessagesWithTags(mailbox string) (map[string][]string, error) {
	rows, err := d.db.Query(`
		SELECT m.message_id, t.tag
		FROM messages m
		JOIN tags t ON t.message_id = m.id
		WHERE m.mailbox = ?
		ORDER BY m.message_id`, mailbox)
	if err != nil {
		return nil, fmt.Errorf("get messages with tags: %w", err)
	}
	defer rows.Close()

	result := make(map[string][]string)
	for rows.Next() {
		var msgID, tag string
		if err := rows.Scan(&msgID, &tag); err != nil {
			return nil, fmt.Errorf("scan row: %w", err)
		}
		result[msgID] = append(result[msgID], tag)
	}
	return result, rows.Err()
}
