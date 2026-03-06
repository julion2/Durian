package store

import (
	"database/sql"
	"fmt"
	"time"
)

// Enqueue adds a draft to the outbox for sending.
func (d *DB) Enqueue(draftJSON string) (int64, error) {
	result, err := d.db.Exec(
		"INSERT INTO outbox (draft_json, created_at) VALUES (?, ?)",
		draftJSON, time.Now().Unix())
	if err != nil {
		return 0, fmt.Errorf("enqueue: %w", err)
	}
	return result.LastInsertId()
}

// Dequeue returns the next outbox item to send. Items with fewer attempts
// are prioritized, and items with 5+ attempts are skipped as poison messages.
// Returns nil if the queue is empty or all items are exhausted.
func (d *DB) Dequeue() (*OutboxItem, error) {
	row := d.db.QueryRow(`
		SELECT id, draft_json, attempts, last_error, created_at
		FROM outbox
		WHERE attempts < 5
		ORDER BY attempts ASC, created_at ASC
		LIMIT 1`)
	return scanOutboxItem(row)
}

// MarkAttempted increments the attempt count and records the error for an outbox item.
func (d *DB) MarkAttempted(id int64, lastErr string) error {
	_, err := d.db.Exec(
		"UPDATE outbox SET attempts = attempts + 1, last_error = ? WHERE id = ?",
		lastErr, id)
	if err != nil {
		return fmt.Errorf("mark attempted: %w", err)
	}
	return nil
}

// DeleteOutboxItem removes a sent item from the outbox.
func (d *DB) DeleteOutboxItem(id int64) error {
	result, err := d.db.Exec("DELETE FROM outbox WHERE id = ?", id)
	if err != nil {
		return fmt.Errorf("delete outbox item: %w", err)
	}
	rows, _ := result.RowsAffected()
	if rows == 0 {
		return fmt.Errorf("outbox item not found: %d", id)
	}
	return nil
}

// scanOutboxItem scans a single row into an OutboxItem.
func scanOutboxItem(row *sql.Row) (*OutboxItem, error) {
	item := &OutboxItem{}
	var lastErr sql.NullString
	err := row.Scan(&item.ID, &item.DraftJSON, &item.Attempts, &lastErr, &item.CreatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("scan outbox item: %w", err)
	}
	if lastErr.Valid {
		item.LastError = lastErr.String
	}
	return item, nil
}
