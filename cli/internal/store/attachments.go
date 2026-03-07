package store

import (
	"database/sql"
	"fmt"
)

// DeleteAttachmentsByMessageDBID removes all attachments for a message DB row.
func (d *DB) DeleteAttachmentsByMessageDBID(messageDBID int64) error {
	_, err := d.db.Exec("DELETE FROM attachments WHERE message_db_id = ?", messageDBID)
	if err != nil {
		return fmt.Errorf("delete attachments: %w", err)
	}
	return nil
}

// InsertAttachment inserts attachment metadata for a message.
func (d *DB) InsertAttachment(att *Attachment) error {
	tx, err := d.db.Begin()
	if err != nil {
		return fmt.Errorf("begin transaction: %w", err)
	}
	defer tx.Rollback()

	if err := d.insertAttachmentTx(tx, att); err != nil {
		return err
	}
	return tx.Commit()
}

// InsertAttachmentTx inserts attachment metadata within an existing transaction.
func (d *DB) insertAttachmentTx(tx *sql.Tx, att *Attachment) error {
	result, err := tx.Exec(`
		INSERT INTO attachments (message_db_id, part_id, filename, content_type, size, disposition, content_id)
		VALUES (?, ?, ?, ?, ?, ?, ?)`,
		att.MessageDBID, att.PartID, att.Filename, att.ContentType,
		att.Size, att.Disposition, att.ContentID)
	if err != nil {
		return fmt.Errorf("insert attachment: %w", err)
	}
	id, _ := result.LastInsertId()
	att.ID = id
	return nil
}

// GetAttachmentsByMessage returns all attachments for a message by its DB ID.
func (d *DB) GetAttachmentsByMessage(messageDBID int64) ([]Attachment, error) {
	return d.queryAttachments(
		"SELECT id, message_db_id, part_id, filename, content_type, size, disposition, content_id FROM attachments WHERE message_db_id = ? ORDER BY part_id",
		messageDBID)
}

// GetAttachmentsByMessageID returns all attachments for a message by its Message-ID header.
func (d *DB) GetAttachmentsByMessageID(messageID string) ([]Attachment, error) {
	return d.queryAttachments(`
		SELECT a.id, a.message_db_id, a.part_id, a.filename, a.content_type, a.size, a.disposition, a.content_id
		FROM attachments a
		WHERE a.message_db_id = (SELECT id FROM messages WHERE message_id = ? LIMIT 1)
		ORDER BY a.part_id`, messageID)
}

func (d *DB) queryAttachments(query string, args ...interface{}) ([]Attachment, error) {
	rows, err := d.db.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("query attachments: %w", err)
	}
	defer rows.Close()

	var atts []Attachment
	for rows.Next() {
		var a Attachment
		err := rows.Scan(&a.ID, &a.MessageDBID, &a.PartID, &a.Filename,
			&a.ContentType, &a.Size, &a.Disposition, &a.ContentID)
		if err != nil {
			return nil, fmt.Errorf("scan attachment: %w", err)
		}
		atts = append(atts, a)
	}
	return atts, rows.Err()
}
