package handler

import (
	"errors"
	"testing"
	"time"

	"github.com/durian-dev/durian/cli/internal/notmuch"
	"github.com/durian-dev/durian/cli/internal/protocol"
	"github.com/durian-dev/durian/cli/internal/store"
)

func TestHandleDispatchSearch(t *testing.T) {
	mock := notmuch.NewMockClient()
	mock.SearchResults = []notmuch.SearchResult{
		{Thread: "123", Subject: "Test", Authors: "sender@example.com"},
	}

	h := New(mock, nil)
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
	// ShowThread will return empty, causing NOT_FOUND - that's fine for dispatch test
	mock.ThreadMessages = []notmuch.ThreadMessage{}

	h := New(mock, nil)
	cmd := protocol.Command{Cmd: "show", Thread: "abc123"}

	resp := h.Handle(cmd)

	// ShowThread was called
	if len(mock.ShowThreadCalls) != 1 {
		t.Errorf("ShowThread should be called once, got %d calls", len(mock.ShowThreadCalls))
	}
	if mock.ShowThreadCalls[0].ThreadID != "abc123" {
		t.Errorf("ShowThread threadID = %q, want %q", mock.ShowThreadCalls[0].ThreadID, "abc123")
	}

	// Should fail because no messages found
	if resp.OK {
		t.Error("Should return error when no messages found")
	}
	if resp.ErrorCode != protocol.ErrNotFound {
		t.Errorf("ErrorCode = %q, want %q", resp.ErrorCode, protocol.ErrNotFound)
	}
}

func TestHandleDispatchTag(t *testing.T) {
	mock := notmuch.NewMockClient()
	h := New(mock, nil)
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
	h := New(mock, nil)
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

	h := New(mock, nil)
	resp := h.Search("*", 10, 0)

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

	h := New(mock, nil)
	resp := h.Search("nonexistent", 10, 0)

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

	h := New(mock, nil)
	resp := h.Search("*", 10, 0)

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
	h := New(mock, nil)

	h.Search("*", 0, 0)

	if len(mock.SearchCalls) != 1 {
		t.Fatal("Search should be called once")
	}
	if mock.SearchCalls[0].Limit != 50 {
		t.Errorf("Default limit should be 50, got %d", mock.SearchCalls[0].Limit)
	}
}

func TestShowThreadSuccess(t *testing.T) {
	mock := notmuch.NewMockClient()
	mock.ThreadMessages = []notmuch.ThreadMessage{
		{
			ID:        "msg1@example.com",
			Timestamp: 1700000000,
			Headers: map[string]string{
				"From":    "alice@example.com",
				"To":      "bob@example.com",
				"Subject": "Test Subject",
				"Date":    "2023-11-14",
			},
			Tags: []string{"inbox", "unread"},
		},
		{
			ID:        "msg2@example.com",
			Timestamp: 1700001000,
			Headers: map[string]string{
				"From": "bob@example.com",
				"To":   "alice@example.com",
				"Date": "2023-11-14",
			},
			Tags: []string{"inbox"},
		},
	}

	h := New(mock, nil)
	resp := h.ShowThread("abc123")

	// ShowThread should be called
	if len(mock.ShowThreadCalls) != 1 {
		t.Fatal("ShowThread should be called once")
	}
	if mock.ShowThreadCalls[0].ThreadID != "abc123" {
		t.Errorf("ThreadID = %q, want %q", mock.ShowThreadCalls[0].ThreadID, "abc123")
	}

	// Should succeed
	if !resp.OK {
		t.Errorf("Should return OK, got error: %s", resp.Error)
	}
	if resp.Thread == nil {
		t.Fatal("Thread should not be nil")
	}
	if len(resp.Thread.Messages) != 2 {
		t.Errorf("Should have 2 messages, got %d", len(resp.Thread.Messages))
	}
	if resp.Thread.Subject != "Test Subject" {
		t.Errorf("Subject = %q, want %q", resp.Thread.Subject, "Test Subject")
	}
}

func TestShowThreadNotFound(t *testing.T) {
	mock := notmuch.NewMockClient()
	mock.ThreadMessages = []notmuch.ThreadMessage{} // Empty = no messages found

	h := New(mock, nil)
	resp := h.ShowThread("nonexistent")

	if resp.OK {
		t.Error("ShowThread() should return error when no messages found")
	}
	if resp.ErrorCode != protocol.ErrNotFound {
		t.Errorf("ErrorCode = %q, want %q", resp.ErrorCode, protocol.ErrNotFound)
	}
}

func TestShowThreadBackendError(t *testing.T) {
	mock := notmuch.NewMockClient()
	mock.ThreadErr = errors.New("backend unavailable")

	h := New(mock, nil)
	resp := h.ShowThread("abc123")

	if resp.OK {
		t.Error("ShowThread() should return error when backend fails")
	}
	if resp.ErrorCode != protocol.ErrBackendError {
		t.Errorf("ErrorCode = %q, want %q", resp.ErrorCode, protocol.ErrBackendError)
	}
}

func TestTagSuccess(t *testing.T) {
	mock := notmuch.NewMockClient()
	h := New(mock, nil)

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
	h := New(mock, nil)

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

	h := New(mock, nil)
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
	h := New(mock, nil)

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

// --- Store-backed handler tests ---

func newTestStore(t *testing.T) *store.DB {
	t.Helper()
	db, err := store.Open(":memory:")
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	if err := db.Init(); err != nil {
		t.Fatalf("init store: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}

func seedStoreData(t *testing.T, db *store.DB) {
	t.Helper()
	now := time.Now().Unix()

	msgs := []*store.Message{
		{
			MessageID: "msg1@test", Subject: "Hello World",
			FromAddr: "alice@example.com", ToAddrs: "bob@example.com",
			Date: now - 3600, CreatedAt: now, BodyText: "First message body",
			BodyHTML: "<p>First message body</p>", Mailbox: "INBOX", FetchedBody: true,
		},
		{
			MessageID: "msg2@test", Subject: "Re: Hello World",
			FromAddr: "bob@example.com", ToAddrs: "alice@example.com",
			InReplyTo: "<msg1@test>", Refs: "<msg1@test>",
			Date: now, CreatedAt: now, BodyText: "Reply body",
			Mailbox: "INBOX", FetchedBody: true,
		},
		{
			MessageID: "msg3@test", Subject: "Other Thread",
			FromAddr: "charlie@example.com", ToAddrs: "alice@example.com",
			Date: now - 7200, CreatedAt: now, BodyText: "Different thread",
			Mailbox: "INBOX", FetchedBody: true,
		},
	}

	for _, msg := range msgs {
		if err := db.InsertMessage(msg); err != nil {
			t.Fatalf("insert %s: %v", msg.MessageID, err)
		}
	}

	// Add tags
	m1, _ := db.GetByMessageID("msg1@test")
	m2, _ := db.GetByMessageID("msg2@test")
	m3, _ := db.GetByMessageID("msg3@test")

	db.AddTag(m1.ID, "inbox")
	db.AddTag(m1.ID, "unread")
	db.AddTag(m2.ID, "inbox")
	db.AddTag(m3.ID, "inbox")
	db.AddTag(m3.ID, "flagged")
}

func TestNewWithStore(t *testing.T) {
	mock := notmuch.NewMockClient()
	db := newTestStore(t)

	h := NewWithStore(mock, db, nil)

	if h.store != db {
		t.Error("store should be set")
	}
	if !h.useStore {
		t.Error("useStore should be true")
	}
}

func TestStoreSearch(t *testing.T) {
	mock := notmuch.NewMockClient()
	db := newTestStore(t)
	seedStoreData(t, db)

	h := NewWithStore(mock, db, nil)
	resp := h.Search("tag:inbox", 10, 0)

	if !resp.OK {
		t.Fatalf("Search failed: %s", resp.Error)
	}
	if len(resp.Results) == 0 {
		t.Fatal("expected results from store search")
	}

	// Should NOT have called notmuch
	if len(mock.SearchCalls) != 0 {
		t.Error("store path should not call notmuch.Search")
	}
}

func TestStoreSearchWithEnrichment(t *testing.T) {
	mock := notmuch.NewMockClient()
	db := newTestStore(t)
	seedStoreData(t, db)

	h := NewWithStore(mock, db, nil)
	resp := h.Search("tag:inbox", 10, 5)

	if !resp.OK {
		t.Fatalf("Search failed: %s", resp.Error)
	}
	if len(resp.Results) == 0 {
		t.Fatal("expected results")
	}
	if len(resp.Threads) == 0 {
		t.Error("expected enriched threads")
	}
}

func TestStoreShowThread(t *testing.T) {
	mock := notmuch.NewMockClient()
	db := newTestStore(t)
	seedStoreData(t, db)

	// Get the thread ID for msg1 (which shares a thread with msg2)
	m1, _ := db.GetByMessageID("msg1@test")

	h := NewWithStore(mock, db, nil)
	resp := h.ShowThread(m1.ThreadID)

	if !resp.OK {
		t.Fatalf("ShowThread failed: %s", resp.Error)
	}
	if resp.Thread == nil {
		t.Fatal("Thread should not be nil")
	}
	if len(resp.Thread.Messages) != 2 {
		t.Errorf("expected 2 messages in thread, got %d", len(resp.Thread.Messages))
	}
	if resp.Thread.Subject != "Hello World" {
		t.Errorf("Subject = %q, want %q", resp.Thread.Subject, "Hello World")
	}

	// Verify messages have tags
	foundTags := false
	for _, msg := range resp.Thread.Messages {
		if len(msg.Tags) > 0 {
			foundTags = true
			break
		}
	}
	if !foundTags {
		t.Error("expected messages to have tags")
	}

	// Should NOT have called notmuch
	if len(mock.ShowThreadCalls) != 0 {
		t.Error("store path should not call notmuch.ShowThread")
	}
}

func TestStoreShowThreadNotFound(t *testing.T) {
	mock := notmuch.NewMockClient()
	db := newTestStore(t)

	h := NewWithStore(mock, db, nil)
	resp := h.ShowThread("nonexistent")

	if resp.OK {
		t.Error("should fail for nonexistent thread")
	}
	if resp.ErrorCode != protocol.ErrNotFound {
		t.Errorf("ErrorCode = %q, want %q", resp.ErrorCode, protocol.ErrNotFound)
	}
}

func TestStoreShowMessageBody(t *testing.T) {
	mock := notmuch.NewMockClient()
	db := newTestStore(t)
	seedStoreData(t, db)

	h := NewWithStore(mock, db, nil)
	resp := h.ShowMessageBody("msg1@test")

	if !resp.OK {
		t.Fatalf("ShowMessageBody failed: %s", resp.Error)
	}
	if resp.MessageBody == nil {
		t.Fatal("MessageBody should not be nil")
	}
	if resp.MessageBody.Body != "First message body" {
		t.Errorf("Body = %q, want %q", resp.MessageBody.Body, "First message body")
	}
	if resp.MessageBody.HTML != "<p>First message body</p>" {
		t.Errorf("HTML = %q, want %q", resp.MessageBody.HTML, "<p>First message body</p>")
	}
}

func TestStoreShowMessageBodyNotFound(t *testing.T) {
	mock := notmuch.NewMockClient()
	db := newTestStore(t)

	h := NewWithStore(mock, db, nil)
	resp := h.ShowMessageBody("nonexistent@test")

	if resp.OK {
		t.Error("should fail for nonexistent message")
	}
	if resp.ErrorCode != protocol.ErrNotFound {
		t.Errorf("ErrorCode = %q, want %q", resp.ErrorCode, protocol.ErrNotFound)
	}
}

func TestStoreTagDualWrite(t *testing.T) {
	mock := notmuch.NewMockClient()
	db := newTestStore(t)
	seedStoreData(t, db)

	m1, _ := db.GetByMessageID("msg1@test")
	h := NewWithStore(mock, db, nil)

	resp := h.Tag("thread:"+m1.ThreadID, "+archived -unread")

	if !resp.OK {
		t.Fatalf("Tag failed: %s", resp.Error)
	}

	// Notmuch should be called
	if len(mock.TagCalls) != 1 {
		t.Fatal("notmuch.Tag should be called once")
	}

	// Store should also be updated
	tags, err := db.GetTagsByMessageID("msg1@test")
	if err != nil {
		t.Fatalf("get tags: %v", err)
	}
	tagSet := make(map[string]bool)
	for _, tag := range tags {
		tagSet[tag] = true
	}
	if !tagSet["archived"] {
		t.Error("expected 'archived' tag in store")
	}
	if tagSet["unread"] {
		t.Error("'unread' should have been removed from store")
	}
	if !tagSet["inbox"] {
		t.Error("'inbox' should still be in store")
	}
}

func TestStoreListTags(t *testing.T) {
	mock := notmuch.NewMockClient()
	db := newTestStore(t)
	seedStoreData(t, db)

	h := NewWithStore(mock, db, nil)
	resp := h.ListTags()

	if !resp.OK {
		t.Fatalf("ListTags failed: %s", resp.Error)
	}
	if len(resp.Tags) == 0 {
		t.Error("expected tags from store")
	}

	tagSet := make(map[string]bool)
	for _, tag := range resp.Tags {
		tagSet[tag] = true
	}
	if !tagSet["inbox"] || !tagSet["unread"] || !tagSet["flagged"] {
		t.Errorf("expected inbox, unread, flagged; got %v", resp.Tags)
	}
}

func TestSplitTagOps(t *testing.T) {
	add, remove := splitTagOps([]string{"+read", "-unread", "+archived", "-inbox"})

	if len(add) != 2 || add[0] != "read" || add[1] != "archived" {
		t.Errorf("add = %v, want [read archived]", add)
	}
	if len(remove) != 2 || remove[0] != "unread" || remove[1] != "inbox" {
		t.Errorf("remove = %v, want [unread inbox]", remove)
	}
}
