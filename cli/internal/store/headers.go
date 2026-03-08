package store

import "fmt"

// InsertHeader stores a message header. Overwrites if the header already exists.
func (d *DB) InsertHeader(messageDBID int64, name, value string) error {
	_, err := d.db.Exec(
		"INSERT OR REPLACE INTO message_headers (message_id, name, value) VALUES (?, ?, ?)",
		messageDBID, name, value)
	if err != nil {
		return fmt.Errorf("insert header: %w", err)
	}
	return nil
}

// GetHeader returns a single header value for a message. Returns "" if not found.
func (d *DB) GetHeader(messageDBID int64, name string) (string, error) {
	var value string
	err := d.db.QueryRow(
		"SELECT value FROM message_headers WHERE message_id = ? AND name = ?",
		messageDBID, name).Scan(&value)
	if err != nil {
		return "", nil // not found
	}
	return value, nil
}

// HasHeaders returns true if the message has any stored headers.
func (d *DB) HasHeaders(messageDBID int64) (bool, error) {
	var count int
	err := d.db.QueryRow(
		"SELECT COUNT(*) FROM message_headers WHERE message_id = ?",
		messageDBID).Scan(&count)
	if err != nil {
		return false, err
	}
	return count > 0, nil
}

// GetMessageDBID returns the internal DB ID for a message by its RFC822 Message-ID
// and account. Returns 0 if not found.
func (d *DB) GetMessageDBID(messageID, account string) (int64, error) {
	var id int64
	err := d.db.QueryRow(
		"SELECT id FROM messages WHERE message_id = ? AND account = ?",
		messageID, account).Scan(&id)
	if err != nil {
		return 0, nil
	}
	return id, nil
}
