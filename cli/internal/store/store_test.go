package store

import "testing"

func newTestDB(t *testing.T) *DB {
	t.Helper()
	db, err := Open(":memory:")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if err := db.Init(); err != nil {
		t.Fatalf("init: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}

func TestOpenAndInit(t *testing.T) {
	db := newTestDB(t)

	// Verify schema_version exists and is current
	var version int
	err := db.db.QueryRow("SELECT version FROM schema_version WHERE rowid = 1").Scan(&version)
	if err != nil {
		t.Fatalf("read version: %v", err)
	}
	if version != 5 {
		t.Errorf("version = %d, want 5", version)
	}
}

func TestInitIdempotent(t *testing.T) {
	db := newTestDB(t)

	// Calling Init() again should not fail
	if err := db.Init(); err != nil {
		t.Fatalf("second init: %v", err)
	}
}

func TestDefaultDBPath(t *testing.T) {
	path := DefaultDBPath()
	if path == "" {
		t.Fatal("empty path")
	}
	if !contains(path, "email.db") {
		t.Errorf("path %q does not contain email.db", path)
	}
	if !contains(path, ".config/durian/") {
		t.Errorf("path %q does not contain .config/durian/", path)
	}
}

func contains(s, sub string) bool {
	return len(s) >= len(sub) && searchSubstring(s, sub)
}

func searchSubstring(s, sub string) bool {
	for i := 0; i <= len(s)-len(sub); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
