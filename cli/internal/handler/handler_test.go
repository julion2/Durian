package handler

import (
	"errors"
	"testing"

	"github.com/durian-dev/durian/cli/internal/backend/notmuch"
	"github.com/durian-dev/durian/cli/internal/protocol"
)

func TestHandleDispatchSearch(t *testing.T) {
	mock := notmuch.NewMockClient()
	mock.SearchResults = []notmuch.SearchResult{
		{Thread: "123", Subject: "Test", Authors: "sender@example.com"},
	}

	h := New(mock)
	cmd := protocol.Command{Cmd: "search", Query: "*", Limit: 10}

	resp := h.Handle(cmd)

	if !resp.OK {
		t.Errorf("Handle() should return OK, got error: %s", resp.Error)
	}
	if len(mock.SearchCalls) != 1 {
		t.Errorf("Search should be called once, got %d calls", len(mock.SearchCalls))
	}
	if mock.SearchCalls[0].Query != "*" {
		t.Errorf("Search query = %q, want %q", mock.SearchCalls[0].Query, "*")
	}
}

func TestHandleDispatchShowByThread(t *testing.T) {
	mock := notmuch.NewMockClient()
	// GetFiles will return empty, causing NOT_FOUND - that's fine for dispatch test
	mock.Files = []string{}

	h := New(mock)
	cmd := protocol.Command{Cmd: "show", Thread: "abc123"}

	resp := h.Handle(cmd)

	// ShowByThread was called, which calls GetFiles
	if len(mock.GetFilesCalls) != 1 {
		t.Errorf("GetFiles should be called once, got %d calls", len(mock.GetFilesCalls))
	}
	if mock.GetFilesCalls[0].Query != "thread:abc123" {
		t.Errorf("GetFiles query = %q, want %q", mock.GetFilesCalls[0].Query, "thread:abc123")
	}

	// Should fail because no file found
	if resp.OK {
		t.Error("Should return error when no file found")
	}
	if resp.ErrorCode != protocol.ErrNotFound {
		t.Errorf("ErrorCode = %q, want %q", resp.ErrorCode, protocol.ErrNotFound)
	}
}

func TestHandleDispatchTag(t *testing.T) {
	mock := notmuch.NewMockClient()
	h := New(mock)
	cmd := protocol.Command{Cmd: "tag", Query: "thread:123", Tags: "+read -unread"}

	resp := h.Handle(cmd)

	if !resp.OK {
		t.Errorf("Handle() should return OK, got error: %s", resp.Error)
	}
	if len(mock.TagCalls) != 1 {
		t.Errorf("Tag should be called once, got %d calls", len(mock.TagCalls))
	}
	if mock.TagCalls[0].Query != "thread:123" {
		t.Errorf("Tag query = %q, want %q", mock.TagCalls[0].Query, "thread:123")
	}
}

func TestHandleUnknownCommand(t *testing.T) {
	mock := notmuch.NewMockClient()
	h := New(mock)
	cmd := protocol.Command{Cmd: "invalid_command"}

	resp := h.Handle(cmd)

	if resp.OK {
		t.Error("Handle() should return error for unknown command")
	}
	if resp.ErrorCode != protocol.ErrUnknownCmd {
		t.Errorf("ErrorCode = %q, want %q", resp.ErrorCode, protocol.ErrUnknownCmd)
	}
	if resp.Error != "unknown command: invalid_command" {
		t.Errorf("Error = %q, want %q", resp.Error, "unknown command: invalid_command")
	}
}

func TestSearchSuccess(t *testing.T) {
	mock := notmuch.NewMockClient()
	mock.SearchResults = []notmuch.SearchResult{
		{
			Thread:       "thread1",
			Subject:      "First Email",
			Authors:      "alice@example.com",
			DateRelative: "Today",
			Tags:         []string{"inbox", "unread"},
		},
		{
			Thread:       "thread2",
			Subject:      "Second Email",
			Authors:      "bob@example.com",
			DateRelative: "Yesterday",
			Tags:         []string{"inbox"},
		},
	}

	h := New(mock)
	resp := h.Search("*", 10)

	if !resp.OK {
		t.Errorf("Search() should return OK, got error: %s", resp.Error)
	}
	if len(resp.Results) != 2 {
		t.Fatalf("Should have 2 results, got %d", len(resp.Results))
	}

	// Check first result
	if resp.Results[0].ThreadID != "thread1" {
		t.Errorf("First result ThreadID = %q, want %q", resp.Results[0].ThreadID, "thread1")
	}
	if resp.Results[0].Subject != "First Email" {
		t.Errorf("First result Subject = %q, want %q", resp.Results[0].Subject, "First Email")
	}
	if resp.Results[0].From != "alice@example.com" {
		t.Errorf("First result From = %q, want %q", resp.Results[0].From, "alice@example.com")
	}
	if resp.Results[0].Tags != "inbox,unread" {
		t.Errorf("First result Tags = %q, want %q", resp.Results[0].Tags, "inbox,unread")
	}

	// Check second result
	if resp.Results[1].ThreadID != "thread2" {
		t.Errorf("Second result ThreadID = %q, want %q", resp.Results[1].ThreadID, "thread2")
	}
}

func TestSearchEmpty(t *testing.T) {
	mock := notmuch.NewMockClient()
	mock.SearchResults = []notmuch.SearchResult{}

	h := New(mock)
	resp := h.Search("nonexistent", 10)

	if !resp.OK {
		t.Errorf("Search() should return OK even with empty results, got error: %s", resp.Error)
	}
	if len(resp.Results) != 0 {
		t.Errorf("Should have 0 results, got %d", len(resp.Results))
	}
}

func TestSearchBackendError(t *testing.T) {
	mock := notmuch.NewMockClient()
	mock.SearchErr = errors.New("notmuch not found")

	h := New(mock)
	resp := h.Search("*", 10)

	if resp.OK {
		t.Error("Search() should return error when backend fails")
	}
	if resp.ErrorCode != protocol.ErrBackendError {
		t.Errorf("ErrorCode = %q, want %q", resp.ErrorCode, protocol.ErrBackendError)
	}
	if resp.Error != "notmuch not found" {
		t.Errorf("Error = %q, want %q", resp.Error, "notmuch not found")
	}
}

func TestSearchDefaultLimit(t *testing.T) {
	mock := notmuch.NewMockClient()
	h := New(mock)

	h.Search("*", 0)

	if len(mock.SearchCalls) != 1 {
		t.Fatal("Search should be called once")
	}
	if mock.SearchCalls[0].Limit != 50 {
		t.Errorf("Default limit should be 50, got %d", mock.SearchCalls[0].Limit)
	}
}

func TestShowByThreadSuccess(t *testing.T) {
	// This test would need actual file parsing, which requires test fixtures
	// For now, we test the flow up to file lookup

	mock := notmuch.NewMockClient()
	// Return a non-existent file to test the flow
	mock.Files = []string{"/nonexistent/file.eml"}

	h := New(mock)
	resp := h.ShowByThread("abc123")

	// GetFiles should be called with thread: prefix
	if len(mock.GetFilesCalls) != 1 {
		t.Fatal("GetFiles should be called once")
	}
	if mock.GetFilesCalls[0].Query != "thread:abc123" {
		t.Errorf("Query = %q, want %q", mock.GetFilesCalls[0].Query, "thread:abc123")
	}

	// Should fail because file doesn't exist
	if resp.OK {
		t.Error("Should return error for non-existent file")
	}
	if resp.ErrorCode != protocol.ErrFileError {
		t.Errorf("ErrorCode = %q, want %q", resp.ErrorCode, protocol.ErrFileError)
	}
}

func TestShowByThreadNotFound(t *testing.T) {
	mock := notmuch.NewMockClient()
	mock.Files = []string{} // Empty = no files found

	h := New(mock)
	resp := h.ShowByThread("nonexistent")

	if resp.OK {
		t.Error("ShowByThread() should return error when no file found")
	}
	if resp.ErrorCode != protocol.ErrNotFound {
		t.Errorf("ErrorCode = %q, want %q", resp.ErrorCode, protocol.ErrNotFound)
	}
}

func TestShowByThreadBackendError(t *testing.T) {
	mock := notmuch.NewMockClient()
	mock.FilesErr = errors.New("backend unavailable")

	h := New(mock)
	resp := h.ShowByThread("abc123")

	if resp.OK {
		t.Error("ShowByThread() should return error when backend fails")
	}
	if resp.ErrorCode != protocol.ErrBackendError {
		t.Errorf("ErrorCode = %q, want %q", resp.ErrorCode, protocol.ErrBackendError)
	}
}

func TestTagSuccess(t *testing.T) {
	mock := notmuch.NewMockClient()
	h := New(mock)

	resp := h.Tag("thread:123", "+read -unread")

	if !resp.OK {
		t.Errorf("Tag() should return OK, got error: %s", resp.Error)
	}
	if len(mock.TagCalls) != 1 {
		t.Fatal("Tag should be called once")
	}
	if mock.TagCalls[0].Query != "thread:123" {
		t.Errorf("Query = %q, want %q", mock.TagCalls[0].Query, "thread:123")
	}

	// Tags should be split
	expectedTags := []string{"+read", "-unread"}
	if len(mock.TagCalls[0].Tags) != 2 {
		t.Fatalf("Should have 2 tags, got %d", len(mock.TagCalls[0].Tags))
	}
	for i, tag := range expectedTags {
		if mock.TagCalls[0].Tags[i] != tag {
			t.Errorf("Tag[%d] = %q, want %q", i, mock.TagCalls[0].Tags[i], tag)
		}
	}
}

func TestTagEmptyTags(t *testing.T) {
	mock := notmuch.NewMockClient()
	h := New(mock)

	resp := h.Tag("thread:123", "")

	if resp.OK {
		t.Error("Tag() should return error for empty tags")
	}
	if resp.ErrorCode != protocol.ErrInvalidJSON {
		t.Errorf("ErrorCode = %q, want %q", resp.ErrorCode, protocol.ErrInvalidJSON)
	}
	if resp.Error != "no tags provided" {
		t.Errorf("Error = %q, want %q", resp.Error, "no tags provided")
	}
}

func TestTagBackendError(t *testing.T) {
	mock := notmuch.NewMockClient()
	mock.TagErr = errors.New("permission denied")

	h := New(mock)
	resp := h.Tag("thread:123", "+read")

	if resp.OK {
		t.Error("Tag() should return error when backend fails")
	}
	if resp.ErrorCode != protocol.ErrBackendError {
		t.Errorf("ErrorCode = %q, want %q", resp.ErrorCode, protocol.ErrBackendError)
	}
	if resp.Error != "permission denied" {
		t.Errorf("Error = %q, want %q", resp.Error, "permission denied")
	}
}

func TestNewHandler(t *testing.T) {
	mock := notmuch.NewMockClient()
	h := New(mock)

	if h == nil {
		t.Error("New() should not return nil")
	}
	if h.notmuch != mock {
		t.Error("Handler should use provided notmuch client")
	}
	if h.parser == nil {
		t.Error("Handler should have parser")
	}
}
