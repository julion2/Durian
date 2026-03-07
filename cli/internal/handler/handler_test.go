package handler

import (
	"encoding/json"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/durian-dev/durian/cli/internal/notmuch"
	"github.com/durian-dev/durian/cli/internal/protocol"
	"github.com/durian-dev/durian/cli/internal/store"
)

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

func TestNew(t *testing.T) {
	mock := notmuch.NewMockClient()
	db := newTestStore(t)

	h := New(mock, db, nil)

	if h.store != db {
		t.Error("store should be set")
	}
	if h.notmuch != mock {
		t.Error("notmuch should be set")
	}
	if h.parser == nil {
		t.Error("parser should not be nil")
	}
}

func TestHandleDispatch(t *testing.T) {
	mock := notmuch.NewMockClient()
	db := newTestStore(t)
	seedStoreData(t, db)

	h := New(mock, db, nil)

	t.Run("search", func(t *testing.T) {
		cmd := protocol.Command{Cmd: "search", Query: "tag:inbox", Limit: 10}
		resp := h.Handle(cmd)
		if !resp.OK {
			t.Errorf("Handle(search) should return OK, got error: %s", resp.Error)
		}
		if len(resp.Results) == 0 {
			t.Error("expected search results")
		}
	})

	t.Run("show thread", func(t *testing.T) {
		m1, _ := db.GetByMessageID("msg1@test")
		cmd := protocol.Command{Cmd: "show", Thread: m1.ThreadID}
		resp := h.Handle(cmd)
		if !resp.OK {
			t.Errorf("Handle(show) should return OK, got error: %s", resp.Error)
		}
		if resp.Thread == nil {
			t.Error("expected thread content")
		}
	})

	t.Run("tag", func(t *testing.T) {
		m1, _ := db.GetByMessageID("msg1@test")
		cmd := protocol.Command{Cmd: "tag", Query: "thread:" + m1.ThreadID, Tags: "+archived"}
		resp := h.Handle(cmd)
		if !resp.OK {
			t.Errorf("Handle(tag) should return OK, got error: %s", resp.Error)
		}
	})

	t.Run("unknown command", func(t *testing.T) {
		cmd := protocol.Command{Cmd: "invalid_command"}
		resp := h.Handle(cmd)
		if resp.OK {
			t.Error("Handle() should return error for unknown command")
		}
		if resp.ErrorCode != protocol.ErrUnknownCmd {
			t.Errorf("ErrorCode = %q, want %q", resp.ErrorCode, protocol.ErrUnknownCmd)
		}
	})
}

func TestStoreSearch(t *testing.T) {
	mock := notmuch.NewMockClient()
	db := newTestStore(t)
	seedStoreData(t, db)

	h := New(mock, db, nil)
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

	h := New(mock, db, nil)
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

	h := New(mock, db, nil)
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

	h := New(mock, db, nil)
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

	h := New(mock, db, nil)
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

	h := New(mock, db, nil)
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
	h := New(mock, db, nil)

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

	h := New(mock, db, nil)
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

func TestStoreDownloadAttachment(t *testing.T) {
	// Set up notmuch mock with attachment at PartID=5 (MIME tree numbering)
	bodyJSON := `[{"id": 1, "content-type": "multipart/mixed", "content": [
		{"id": 2, "content-type": "text/plain", "content": "See attached"},
		{"id": 5, "content-type": "application/pdf", "content-disposition": "attachment", "content-length": 100, "filename": "report.pdf"}
	]}]`
	var body []json.RawMessage
	if err := json.Unmarshal([]byte(bodyJSON), &body); err != nil {
		t.Fatalf("unmarshal body: %v", err)
	}

	mock := notmuch.NewMockClient()
	mock.ThreadMessages = []notmuch.ThreadMessage{
		{ID: "msg1@test", Body: body},
	}
	mock.ShowRawPartData = []byte("fake-pdf-bytes")

	// Set up store with attachment at sequential PartID=1
	db := newTestStore(t)
	msg := &store.Message{
		MessageID: "msg1@test", Subject: "Test",
		FromAddr: "a@test", ToAddrs: "b@test",
		Date: time.Now().Unix(), CreatedAt: time.Now().Unix(),
		Mailbox: "INBOX", FetchedBody: true,
	}
	if err := db.InsertMessage(msg); err != nil {
		t.Fatalf("insert message: %v", err)
	}
	if err := db.InsertAttachment(&store.Attachment{
		MessageDBID: msg.ID, PartID: 1,
		Filename: "report.pdf", ContentType: "application/pdf",
		Size: 100, Disposition: "attachment",
	}); err != nil {
		t.Fatalf("insert attachment: %v", err)
	}

	h := New(mock, db, nil)
	w := httptest.NewRecorder()

	err := h.DownloadAttachment("msg1@test", 1, w)
	if err != nil {
		t.Fatalf("DownloadAttachment failed: %v", err)
	}

	// Verify response headers
	if ct := w.Header().Get("Content-Type"); ct != "application/pdf" {
		t.Errorf("Content-Type = %q, want application/pdf", ct)
	}
	if cd := w.Header().Get("Content-Disposition"); cd != `attachment; filename="report.pdf"` {
		t.Errorf("Content-Disposition = %q, want attachment; filename=\"report.pdf\"", cd)
	}

	// Verify body streamed from notmuch
	if w.Body.String() != "fake-pdf-bytes" {
		t.Errorf("Body = %q, want fake-pdf-bytes", w.Body.String())
	}
}

func TestStoreDownloadAttachmentNotFound(t *testing.T) {
	mock := notmuch.NewMockClient()
	db := newTestStore(t)

	h := New(mock, db, nil)
	w := httptest.NewRecorder()

	err := h.DownloadAttachment("nonexistent@test", 1, w)
	if err == nil {
		t.Error("expected error for nonexistent attachment")
	}
}
