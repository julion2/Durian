package store

import (
	"fmt"
	"time"
)

// LocalDraft represents a locally-saved draft for crash recovery.
type LocalDraft struct {
	ID         string
	DraftJSON  string
	CreatedAt  int64
	ModifiedAt int64
}

// SaveLocalDraft upserts a local draft by ID.
func (d *DB) SaveLocalDraft(draft *LocalDraft) error {
	now := time.Now().Unix()
	if draft.CreatedAt == 0 {
		draft.CreatedAt = now
	}
	draft.ModifiedAt = now

	_, err := d.db.Exec(`
		INSERT INTO local_drafts (id, draft_json, created_at, modified_at)
		VALUES (?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET
			draft_json = excluded.draft_json,
			modified_at = excluded.modified_at`,
		draft.ID, draft.DraftJSON, draft.CreatedAt, draft.ModifiedAt)
	if err != nil {
		return fmt.Errorf("save local draft: %w", err)
	}
	return nil
}

// GetLocalDraft retrieves a local draft by ID.
func (d *DB) GetLocalDraft(id string) (*LocalDraft, error) {
	draft := &LocalDraft{}
	err := d.db.QueryRow(
		"SELECT id, draft_json, created_at, modified_at FROM local_drafts WHERE id = ?", id,
	).Scan(&draft.ID, &draft.DraftJSON, &draft.CreatedAt, &draft.ModifiedAt)
	if err != nil {
		return nil, fmt.Errorf("get local draft: %w", err)
	}
	return draft, nil
}

// DeleteLocalDraft removes a local draft by ID.
func (d *DB) DeleteLocalDraft(id string) error {
	result, err := d.db.Exec("DELETE FROM local_drafts WHERE id = ?", id)
	if err != nil {
		return fmt.Errorf("delete local draft: %w", err)
	}
	rows, _ := result.RowsAffected()
	if rows == 0 {
		return fmt.Errorf("local draft not found: %s", id)
	}
	return nil
}

// ListLocalDrafts returns all local drafts, newest first.
func (d *DB) ListLocalDrafts() ([]*LocalDraft, error) {
	rows, err := d.db.Query(
		"SELECT id, draft_json, created_at, modified_at FROM local_drafts ORDER BY modified_at DESC")
	if err != nil {
		return nil, fmt.Errorf("list local drafts: %w", err)
	}
	defer rows.Close()

	var drafts []*LocalDraft
	for rows.Next() {
		draft := &LocalDraft{}
		if err := rows.Scan(&draft.ID, &draft.DraftJSON, &draft.CreatedAt, &draft.ModifiedAt); err != nil {
			return nil, fmt.Errorf("scan local draft: %w", err)
		}
		drafts = append(drafts, draft)
	}
	return drafts, rows.Err()
}
