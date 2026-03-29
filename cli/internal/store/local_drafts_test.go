package store

import "testing"

func TestSaveAndGetLocalDraft(t *testing.T) {
	db := newTestDB(t)

	draft := &LocalDraft{
		ID:        "aaa-bbb-ccc",
		DraftJSON: `{"subject":"Hello","to":["bob@x.com"]}`,
	}
	if err := db.SaveLocalDraft(draft); err != nil {
		t.Fatalf("save: %v", err)
	}
	if draft.CreatedAt == 0 || draft.ModifiedAt == 0 {
		t.Fatal("timestamps not set")
	}

	got, err := db.GetLocalDraft("aaa-bbb-ccc")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if got.DraftJSON != draft.DraftJSON {
		t.Errorf("draft_json = %q, want %q", got.DraftJSON, draft.DraftJSON)
	}
	if got.CreatedAt != draft.CreatedAt {
		t.Errorf("created_at = %d, want %d", got.CreatedAt, draft.CreatedAt)
	}
}

func TestSaveLocalDraft_Upsert(t *testing.T) {
	db := newTestDB(t)

	draft := &LocalDraft{ID: "xxx", DraftJSON: `{"v":1}`}
	if err := db.SaveLocalDraft(draft); err != nil {
		t.Fatalf("save: %v", err)
	}
	originalCreated := draft.CreatedAt

	// Update same ID
	draft2 := &LocalDraft{ID: "xxx", DraftJSON: `{"v":2}`}
	if err := db.SaveLocalDraft(draft2); err != nil {
		t.Fatalf("upsert: %v", err)
	}

	got, _ := db.GetLocalDraft("xxx")
	if got.DraftJSON != `{"v":2}` {
		t.Errorf("draft_json not updated: %q", got.DraftJSON)
	}
	if got.CreatedAt != originalCreated {
		t.Error("created_at should not change on upsert")
	}
}

func TestGetLocalDraft_NotFound(t *testing.T) {
	db := newTestDB(t)

	_, err := db.GetLocalDraft("nonexistent")
	if err == nil {
		t.Fatal("expected error for missing draft")
	}
}

func TestDeleteLocalDraft(t *testing.T) {
	db := newTestDB(t)

	db.SaveLocalDraft(&LocalDraft{ID: "del-me", DraftJSON: `{}`})

	if err := db.DeleteLocalDraft("del-me"); err != nil {
		t.Fatalf("delete: %v", err)
	}

	_, err := db.GetLocalDraft("del-me")
	if err == nil {
		t.Fatal("draft should be deleted")
	}
}

func TestDeleteLocalDraft_NotFound(t *testing.T) {
	db := newTestDB(t)

	err := db.DeleteLocalDraft("nope")
	if err == nil {
		t.Fatal("expected error for missing draft")
	}
}

func TestListLocalDrafts(t *testing.T) {
	db := newTestDB(t)

	db.SaveLocalDraft(&LocalDraft{ID: "a", DraftJSON: `{"n":1}`})
	db.SaveLocalDraft(&LocalDraft{ID: "b", DraftJSON: `{"n":2}`})
	db.SaveLocalDraft(&LocalDraft{ID: "c", DraftJSON: `{"n":3}`})

	drafts, err := db.ListLocalDrafts()
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(drafts) != 3 {
		t.Fatalf("got %d drafts, want 3", len(drafts))
	}
	ids := make(map[string]bool)
	for _, d := range drafts {
		ids[d.ID] = true
	}
	if !ids["a"] || !ids["b"] || !ids["c"] {
		t.Errorf("missing drafts, got %v", ids)
	}
}

func TestListLocalDrafts_Empty(t *testing.T) {
	db := newTestDB(t)

	drafts, err := db.ListLocalDrafts()
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(drafts) != 0 {
		t.Fatalf("got %d drafts, want 0", len(drafts))
	}
}
