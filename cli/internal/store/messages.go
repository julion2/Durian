package store

import (
	"database/sql"
	"fmt"
)

// InsertMessage inserts or upserts a single message, resolving its thread ID.
func (d *DB) InsertMessage(msg *Message) error {
	tx, err := d.db.Begin()
	if err != nil {
		return fmt.Errorf("begin transaction: %w", err)
	}
	defer tx.Rollback()

	if err := d.insertMessageTx(tx, msg); err != nil {
		return err
	}

	return tx.Commit()
}

// InsertBatch inserts multiple messages in a single transaction.
// Thread resolution within the batch sees earlier inserts (tx visibility).
func (d *DB) InsertBatch(msgs []*Message) error {
	tx, err := d.db.Begin()
	if err != nil {
		return fmt.Errorf("begin transaction: %w", err)
	}
	defer tx.Rollback()

	for _, msg := range msgs {
		if err := d.insertMessageTx(tx, msg); err != nil {
			return fmt.Errorf("insert %q: %w", msg.MessageID, err)
		}
	}

	return tx.Commit()
}

// insertMessageTx inserts a message within an existing transaction.
func (d *DB) insertMessageTx(tx *sql.Tx, msg *Message) error {
	threadID, err := resolveThreadID(tx, msg.MessageID, msg.InReplyTo, msg.Refs)
	if err != nil {
		return fmt.Errorf("resolve thread: %w", err)
	}
	msg.ThreadID = threadID

	fetchedBody := 0
	if msg.FetchedBody {
		fetchedBody = 1
	}

	err = tx.QueryRow(`
		INSERT INTO messages (
			message_id, thread_id, in_reply_to, refs, subject,
			from_addr, to_addrs, cc_addrs, date, created_at,
			body_text, body_html, mailbox, flags, uid, size, fetched_body
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(message_id) DO UPDATE SET
			body_text = CASE WHEN excluded.fetched_body = 1 AND messages.fetched_body = 0
			                 THEN excluded.body_text ELSE messages.body_text END,
			body_html = CASE WHEN excluded.fetched_body = 1 AND messages.fetched_body = 0
			                 THEN excluded.body_html ELSE messages.body_html END,
			fetched_body = MAX(messages.fetched_body, excluded.fetched_body),
			flags = excluded.flags
		RETURNING id`,
		msg.MessageID, threadID, msg.InReplyTo, msg.Refs, msg.Subject,
		msg.FromAddr, msg.ToAddrs, msg.CCAddrs, msg.Date, msg.CreatedAt,
		msg.BodyText, msg.BodyHTML, msg.Mailbox, msg.Flags, msg.UID, msg.Size, fetchedBody,
	).Scan(&msg.ID)
	if err != nil {
		return fmt.Errorf("upsert message: %w", err)
	}

	return nil
}

// UpdateBody updates the body text and HTML for a message (lazy body fetch).
func (d *DB) UpdateBody(messageID, bodyText, bodyHTML string) error {
	result, err := d.db.Exec(`
		UPDATE messages SET body_text = ?, body_html = ?, fetched_body = 1
		WHERE message_id = ?`,
		bodyText, bodyHTML, messageID)
	if err != nil {
		return fmt.Errorf("update body: %w", err)
	}
	rows, _ := result.RowsAffected()
	if rows == 0 {
		return fmt.Errorf("message not found: %s", messageID)
	}
	return nil
}

// GetByMessageID retrieves a message by its Message-ID header value.
func (d *DB) GetByMessageID(messageID string) (*Message, error) {
	msg := &Message{}
	var fetchedBody int
	err := d.db.QueryRow(`
		SELECT id, message_id, thread_id, in_reply_to, refs, subject,
		       from_addr, to_addrs, cc_addrs, date, created_at,
		       body_text, body_html, mailbox, flags, uid, size, fetched_body
		FROM messages WHERE message_id = ?`, messageID,
	).Scan(
		&msg.ID, &msg.MessageID, &msg.ThreadID, &msg.InReplyTo, &msg.Refs, &msg.Subject,
		&msg.FromAddr, &msg.ToAddrs, &msg.CCAddrs, &msg.Date, &msg.CreatedAt,
		&msg.BodyText, &msg.BodyHTML, &msg.Mailbox, &msg.Flags, &msg.UID, &msg.Size, &fetchedBody,
	)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("get by message_id: %w", err)
	}
	msg.FetchedBody = fetchedBody == 1
	return msg, nil
}

// GetByThread retrieves all messages in a thread, ordered by date ascending.
func (d *DB) GetByThread(threadID string) ([]*Message, error) {
	rows, err := d.db.Query(`
		SELECT id, message_id, thread_id, in_reply_to, refs, subject,
		       from_addr, to_addrs, cc_addrs, date, created_at,
		       body_text, body_html, mailbox, flags, uid, size, fetched_body
		FROM messages WHERE thread_id = ?
		ORDER BY date ASC`, threadID)
	if err != nil {
		return nil, fmt.Errorf("get by thread: %w", err)
	}
	defer rows.Close()

	return scanMessages(rows)
}

// MessageExists checks if a message with the given Message-ID exists.
func (d *DB) MessageExists(messageID string) (bool, error) {
	var count int
	err := d.db.QueryRow("SELECT COUNT(*) FROM messages WHERE message_id = ?", messageID).Scan(&count)
	if err != nil {
		return false, fmt.Errorf("check message exists: %w", err)
	}
	return count > 0, nil
}

// GetAllMessageIDSet returns a set of all Message-IDs in the store.
// Used for efficient bulk existence checks during backfill.
func (d *DB) GetAllMessageIDSet() (map[string]bool, error) {
	rows, err := d.db.Query("SELECT message_id FROM messages")
	if err != nil {
		return nil, fmt.Errorf("get all message ids: %w", err)
	}
	defer rows.Close()

	result := make(map[string]bool)
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scan message id: %w", err)
		}
		result[id] = true
	}
	return result, rows.Err()
}

// DeleteByMessageID deletes a message by its Message-ID header value.
func (d *DB) DeleteByMessageID(messageID string) error {
	result, err := d.db.Exec("DELETE FROM messages WHERE message_id = ?", messageID)
	if err != nil {
		return fmt.Errorf("delete message: %w", err)
	}
	rows, _ := result.RowsAffected()
	if rows == 0 {
		return fmt.Errorf("message not found: %s", messageID)
	}
	return nil
}

// scanMessages scans rows into a slice of Message pointers.
func scanMessages(rows *sql.Rows) ([]*Message, error) {
	var msgs []*Message
	for rows.Next() {
		msg := &Message{}
		var fetchedBody int
		err := rows.Scan(
			&msg.ID, &msg.MessageID, &msg.ThreadID, &msg.InReplyTo, &msg.Refs, &msg.Subject,
			&msg.FromAddr, &msg.ToAddrs, &msg.CCAddrs, &msg.Date, &msg.CreatedAt,
			&msg.BodyText, &msg.BodyHTML, &msg.Mailbox, &msg.Flags, &msg.UID, &msg.Size, &fetchedBody,
		)
		if err != nil {
			return nil, fmt.Errorf("scan message: %w", err)
		}
		msg.FetchedBody = fetchedBody == 1
		msgs = append(msgs, msg)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate message rows: %w", err)
	}
	return msgs, nil
}
