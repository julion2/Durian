package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
)

func setupTestServer(t *testing.T) {
	t.Helper()
	tmpDB, err := os.CreateTemp("", "sync-test-*.db")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Remove(tmpDB.Name()) })

	var openErr error
	db, openErr = openDB(tmpDB.Name())
	if openErr != nil {
		t.Fatal(openErr)
	}
	t.Cleanup(func() { db.Close() })

	if err := initDB(); err != nil {
		t.Fatal(err)
	}
	apiKey = "test-key"
}

func TestHealth(t *testing.T) {
	req := httptest.NewRequest("GET", "/health", nil)
	w := httptest.NewRecorder()
	handleHealth(w, req)

	if w.Code != 200 {
		t.Errorf("status = %d, want 200", w.Code)
	}
	var resp map[string]string
	json.NewDecoder(w.Body).Decode(&resp)
	if resp["status"] != "ok" {
		t.Errorf("status = %q, want ok", resp["status"])
	}
}

func TestAuthMiddleware_ValidKey(t *testing.T) {
	setupTestServer(t)
	handler := authMiddleware(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
	})

	req := httptest.NewRequest("GET", "/v1/sync", nil)
	req.Header.Set("X-API-Key", "test-key")
	w := httptest.NewRecorder()
	handler(w, req)

	if w.Code != 200 {
		t.Errorf("status = %d, want 200", w.Code)
	}
}

func TestAuthMiddleware_InvalidKey(t *testing.T) {
	setupTestServer(t)
	handler := authMiddleware(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
	})

	req := httptest.NewRequest("GET", "/v1/sync", nil)
	req.Header.Set("X-API-Key", "wrong-key")
	w := httptest.NewRecorder()
	handler(w, req)

	if w.Code != 401 {
		t.Errorf("status = %d, want 401", w.Code)
	}
}

func TestAuthMiddleware_MissingKey(t *testing.T) {
	setupTestServer(t)
	handler := authMiddleware(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
	})

	req := httptest.NewRequest("GET", "/v1/sync", nil)
	w := httptest.NewRecorder()
	handler(w, req)

	if w.Code != 401 {
		t.Errorf("status = %d, want 401", w.Code)
	}
}

func TestPostSync(t *testing.T) {
	setupTestServer(t)

	body, _ := json.Marshal(SyncRequest{
		ClientID: "mac1",
		Changes: []TagChange{
			{MessageID: "abc@x.com", Account: "work", Tag: "important", Action: "add", Timestamp: 1000},
			{MessageID: "abc@x.com", Account: "work", Tag: "urgent", Action: "add", Timestamp: 1000},
		},
	})

	req := httptest.NewRequest("POST", "/v1/sync", bytes.NewReader(body))
	w := httptest.NewRecorder()
	handlePostSync(w, req)

	if w.Code != 200 {
		t.Fatalf("status = %d, want 200", w.Code)
	}

	var resp map[string]any
	json.NewDecoder(w.Body).Decode(&resp)
	if resp["ok"] != true {
		t.Error("expected ok=true")
	}
	if resp["count"].(float64) != 2 {
		t.Errorf("count = %v, want 2", resp["count"])
	}
}

func TestPostSync_InvalidAction(t *testing.T) {
	setupTestServer(t)

	body, _ := json.Marshal(SyncRequest{
		ClientID: "mac1",
		Changes: []TagChange{
			{MessageID: "abc@x.com", Account: "work", Tag: "x", Action: "invalid", Timestamp: 1000},
		},
	})

	req := httptest.NewRequest("POST", "/v1/sync", bytes.NewReader(body))
	w := httptest.NewRecorder()
	handlePostSync(w, req)

	var resp map[string]any
	json.NewDecoder(w.Body).Decode(&resp)
	if resp["count"].(float64) != 0 {
		t.Errorf("count = %v, want 0 (invalid action skipped)", resp["count"])
	}
}

func TestPostSync_EmptyChanges(t *testing.T) {
	setupTestServer(t)

	body, _ := json.Marshal(SyncRequest{ClientID: "mac1", Changes: []TagChange{}})
	req := httptest.NewRequest("POST", "/v1/sync", bytes.NewReader(body))
	w := httptest.NewRecorder()
	handlePostSync(w, req)

	var resp map[string]any
	json.NewDecoder(w.Body).Decode(&resp)
	if resp["count"].(float64) != 0 {
		t.Errorf("count = %v, want 0", resp["count"])
	}
}

func TestGetSync_PullAll(t *testing.T) {
	setupTestServer(t)

	// Push two changes from mac1
	body, _ := json.Marshal(SyncRequest{
		ClientID: "mac1",
		Changes: []TagChange{
			{MessageID: "a@x", Account: "w", Tag: "inbox", Action: "add", Timestamp: 100},
			{MessageID: "b@x", Account: "w", Tag: "sent", Action: "add", Timestamp: 200},
		},
	})
	req := httptest.NewRequest("POST", "/v1/sync", bytes.NewReader(body))
	w := httptest.NewRecorder()
	handlePostSync(w, req)

	// Pull from mac2 — should see both
	req = httptest.NewRequest("GET", "/v1/sync?since=0&client_id=mac2", nil)
	w = httptest.NewRecorder()
	handleGetSync(w, req)

	var resp SyncResponse
	json.NewDecoder(w.Body).Decode(&resp)
	if len(resp.Changes) != 2 {
		t.Errorf("got %d changes, want 2", len(resp.Changes))
	}
}

func TestGetSync_ExcludesOwnClient(t *testing.T) {
	setupTestServer(t)

	body, _ := json.Marshal(SyncRequest{
		ClientID: "mac1",
		Changes: []TagChange{
			{MessageID: "a@x", Account: "w", Tag: "inbox", Action: "add", Timestamp: 100},
		},
	})
	req := httptest.NewRequest("POST", "/v1/sync", bytes.NewReader(body))
	w := httptest.NewRecorder()
	handlePostSync(w, req)

	// Pull from mac1 — should see nothing (own changes excluded)
	req = httptest.NewRequest("GET", "/v1/sync?since=0&client_id=mac1", nil)
	w = httptest.NewRecorder()
	handleGetSync(w, req)

	var resp SyncResponse
	json.NewDecoder(w.Body).Decode(&resp)
	if len(resp.Changes) != 0 {
		t.Errorf("got %d changes, want 0 (own excluded)", len(resp.Changes))
	}
}

func TestGetSync_SinceTimestamp(t *testing.T) {
	setupTestServer(t)

	body, _ := json.Marshal(SyncRequest{
		ClientID: "mac1",
		Changes: []TagChange{
			{MessageID: "a@x", Account: "w", Tag: "old", Action: "add", Timestamp: 100},
			{MessageID: "b@x", Account: "w", Tag: "new", Action: "add", Timestamp: 200},
		},
	})
	req := httptest.NewRequest("POST", "/v1/sync", bytes.NewReader(body))
	w := httptest.NewRecorder()
	handlePostSync(w, req)

	// Pull since=150 — only the second change
	req = httptest.NewRequest("GET", "/v1/sync?since=150&client_id=mac2", nil)
	w = httptest.NewRecorder()
	handleGetSync(w, req)

	var resp SyncResponse
	json.NewDecoder(w.Body).Decode(&resp)
	if len(resp.Changes) != 1 {
		t.Fatalf("got %d changes, want 1", len(resp.Changes))
	}
	if resp.Changes[0].Tag != "new" {
		t.Errorf("tag = %q, want new", resp.Changes[0].Tag)
	}
}

func TestGetSync_DeduplicatesPerMessageTag(t *testing.T) {
	setupTestServer(t)

	// Same (message_id, account, tag) added then removed — only latest action returned
	body, _ := json.Marshal(SyncRequest{
		ClientID: "mac1",
		Changes: []TagChange{
			{MessageID: "a@x", Account: "w", Tag: "inbox", Action: "add", Timestamp: 100},
			{MessageID: "a@x", Account: "w", Tag: "inbox", Action: "remove", Timestamp: 200},
		},
	})
	req := httptest.NewRequest("POST", "/v1/sync", bytes.NewReader(body))
	w := httptest.NewRecorder()
	handlePostSync(w, req)

	req = httptest.NewRequest("GET", "/v1/sync?since=0&client_id=mac2", nil)
	w = httptest.NewRecorder()
	handleGetSync(w, req)

	var resp SyncResponse
	json.NewDecoder(w.Body).Decode(&resp)
	if len(resp.Changes) != 1 {
		t.Fatalf("got %d changes, want 1 (deduplicated)", len(resp.Changes))
	}
	if resp.Changes[0].Action != "remove" {
		t.Errorf("action = %q, want remove (latest)", resp.Changes[0].Action)
	}
}

func TestSyncMethodNotAllowed(t *testing.T) {
	req := httptest.NewRequest("PUT", "/v1/sync", nil)
	w := httptest.NewRecorder()
	handleSync(w, req)

	if w.Code != 405 {
		t.Errorf("status = %d, want 405", w.Code)
	}
}
