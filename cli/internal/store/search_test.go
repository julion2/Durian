package store

import (
	"testing"
	"time"
)

func seedSearchDB(t *testing.T) *DB {
	t.Helper()
	db := newTestDB(t)
	now := time.Now().Unix()

	messages := []*Message{
		{MessageID: "s1@x", Subject: "Invoice for January", FromAddr: "alice@example.com",
			ToAddrs: "bob@example.com", Date: now - 3600, CreatedAt: now, BodyText: "Please find the invoice attached.", Mailbox: "INBOX", FetchedBody: true},
		{MessageID: "s2@x", Subject: "Meeting tomorrow", FromAddr: "bob@example.com",
			ToAddrs: "alice@example.com", Date: now - 1800, CreatedAt: now, BodyText: "Let's discuss the project plan.", Mailbox: "INBOX", FetchedBody: true},
		{MessageID: "s3@x", Subject: "Re: Meeting tomorrow", FromAddr: "alice@example.com",
			ToAddrs: "bob@example.com", InReplyTo: "<s2@x>", Refs: "<s2@x>",
			Date: now - 900, CreatedAt: now, BodyText: "Sounds good, see you then.", Mailbox: "INBOX", FetchedBody: true},
		{MessageID: "s4@x", Subject: "Weekly report", FromAddr: "charlie@example.com",
			ToAddrs: "team@example.com", Date: now - 600, CreatedAt: now, BodyText: "Attached is the weekly report with invoice details.", Mailbox: "INBOX", FetchedBody: true},
		{MessageID: "s5@x", Subject: "Vacation plans", FromAddr: "alice@example.com",
			ToAddrs: "family@example.com", Date: now - 300, CreatedAt: now, BodyText: "I'm thinking about Hawaii.", Mailbox: "Sent", FetchedBody: true},
	}

	for _, msg := range messages {
		if err := db.InsertMessage(msg); err != nil {
			t.Fatalf("seed %s: %v", msg.MessageID, err)
		}
	}

	// Add some tags
	for _, msg := range messages {
		m, _ := db.GetByMessageID(msg.MessageID)
		db.AddTag(m.ID, "inbox")
	}
	m1, _ := db.GetByMessageID("s1@x")
	db.AddTag(m1.ID, "unread")

	return db
}

func TestSearch_All(t *testing.T) {
	db := seedSearchDB(t)
	results, err := db.Search("*", 50)
	if err != nil {
		t.Fatalf("search *: %v", err)
	}
	if len(results) == 0 {
		t.Error("expected results for *")
	}
}

func TestSearch_FromField(t *testing.T) {
	db := seedSearchDB(t)
	results, err := db.Search("from:alice", 10)
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	// alice sent s1, s3, s5 — s3 is in same thread as s2
	// Thread grouping: s1 thread, s2+s3 thread, s5 thread → alice appears in 3 threads
	if len(results) < 2 {
		t.Errorf("got %d results for from:alice, want at least 2", len(results))
	}
}

func TestSearch_Tag(t *testing.T) {
	db := seedSearchDB(t)
	results, err := db.Search("tag:unread", 10)
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	if len(results) != 1 {
		t.Errorf("got %d results for tag:unread, want 1", len(results))
	}
}

func TestSearch_NotTag(t *testing.T) {
	db := seedSearchDB(t)
	all, _ := db.Search("*", 50)
	withoutUnread, _ := db.Search("NOT tag:unread", 50)

	if len(withoutUnread) >= len(all) {
		t.Errorf("NOT tag:unread (%d) should have fewer results than * (%d)",
			len(withoutUnread), len(all))
	}
}

func TestSearch_FTS_BodyText(t *testing.T) {
	db := seedSearchDB(t)
	results, err := db.Search("invoice", 10)
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	// "invoice" appears in s1 (subject+body) and s4 (body)
	if len(results) < 1 {
		t.Errorf("got %d results for 'invoice', want at least 1", len(results))
	}
}

func TestSearch_Subject(t *testing.T) {
	db := seedSearchDB(t)
	results, err := db.Search("subject:vacation", 10)
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	if len(results) != 1 {
		t.Errorf("got %d results for subject:vacation, want 1", len(results))
	}
}

func TestSearch_ThreadGrouping(t *testing.T) {
	db := seedSearchDB(t)
	// s2 and s3 are in the same thread — should appear as one result
	results, err := db.Search("from:bob", 10)
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	// bob sent s2, which is in thread with s3 → 1 thread
	if len(results) != 1 {
		t.Errorf("got %d results for from:bob, want 1 (thread grouping)", len(results))
	}
}

func TestSearch_ResultHasTags(t *testing.T) {
	db := seedSearchDB(t)
	results, err := db.Search("tag:unread", 10)
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	if len(results) == 0 {
		t.Fatal("no results")
	}
	if len(results[0].Tags) == 0 {
		t.Error("result should have tags")
	}
}

func TestSearch_Limit(t *testing.T) {
	db := seedSearchDB(t)
	results, err := db.Search("*", 2)
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	if len(results) > 2 {
		t.Errorf("got %d results with limit 2", len(results))
	}
}

func TestTokenize(t *testing.T) {
	tests := []struct {
		query string
		count int
	}{
		{"*", 1},
		{"", 1},
		{"from:alice", 1},
		{"from:alice tag:inbox", 2},
		{"NOT tag:spam", 1},
		{"hello world", 2},
		{"from:alice subject:meeting hello", 3},
	}
	for _, tt := range tests {
		tokens := tokenize(tt.query)
		if len(tokens) != tt.count {
			t.Errorf("tokenize(%q) = %d tokens, want %d", tt.query, len(tokens), tt.count)
		}
	}
}

func TestTokenize_NotField(t *testing.T) {
	tokens := tokenize("NOT tag:spam")
	if len(tokens) != 1 {
		t.Fatalf("expected 1 token, got %d", len(tokens))
	}
	if tokens[0].kind != "not_field" {
		t.Errorf("kind = %q, want not_field", tokens[0].kind)
	}
	if tokens[0].field != "tag" || tokens[0].value != "spam" {
		t.Errorf("token = %+v, want tag:spam", tokens[0])
	}
}

func TestFormatDateRelative(t *testing.T) {
	now := time.Now()

	// Today
	ts := now.Add(-1 * time.Hour).Unix()
	r := formatDateRelative(ts)
	if r == "" {
		t.Error("empty for today")
	}

	// Far past
	old := time.Date(2020, 1, 15, 10, 30, 0, 0, time.UTC).Unix()
	r = formatDateRelative(old)
	if r != "2020-01-15" {
		t.Errorf("old date = %q, want 2020-01-15", r)
	}
}

func TestSearch_DateRange(t *testing.T) {
	db := newTestDB(t)

	// Insert messages at known dates
	jan := time.Date(2024, 1, 15, 12, 0, 0, 0, time.UTC).Unix()
	jun := time.Date(2024, 6, 15, 12, 0, 0, 0, time.UTC).Unix()

	db.InsertMessage(&Message{
		MessageID: "jan@x", Subject: "January msg", FromAddr: "a@x",
		Date: jan, CreatedAt: jan, FetchedBody: true,
	})
	db.InsertMessage(&Message{
		MessageID: "jun@x", Subject: "June msg", FromAddr: "a@x",
		Date: jun, CreatedAt: jun, FetchedBody: true,
	})

	results, err := db.Search("date:2024-01..2024-03", 10)
	if err != nil {
		t.Fatalf("date search: %v", err)
	}
	if len(results) != 1 {
		t.Errorf("got %d results for Jan-Mar range, want 1", len(results))
	}
}

func TestSearch_AccountFilter(t *testing.T) {
	db := newTestDB(t)
	now := time.Now().Unix()

	db.InsertMessage(&Message{
		MessageID: "acc1@x", Subject: "From work", FromAddr: "a@x",
		Date: now, CreatedAt: now, FetchedBody: true, Account: "work",
	})
	db.InsertMessage(&Message{
		MessageID: "acc2@x", Subject: "From personal", FromAddr: "b@x",
		Date: now - 100, CreatedAt: now, FetchedBody: true, Account: "personal",
	})
	// Cross-account message: one row per account
	db.InsertMessage(&Message{
		MessageID: "acc3@x", Subject: "Cross account", FromAddr: "c@x",
		Date: now - 200, CreatedAt: now, FetchedBody: true, Account: "work",
	})
	db.InsertMessage(&Message{
		MessageID: "acc3@x", Subject: "Cross account", FromAddr: "c@x",
		Date: now - 200, CreatedAt: now, FetchedBody: true, Account: "personal",
	})

	// path:work/** should match acc1 and acc3
	results, err := db.Search("path:work/**", 10)
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	if len(results) != 2 {
		t.Errorf("got %d results for path:work/**, want 2", len(results))
	}

	// path:personal/** should match acc2 and acc3
	results, err = db.Search("path:personal/**", 10)
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	if len(results) != 2 {
		t.Errorf("got %d results for path:personal/**, want 2", len(results))
	}
}

func TestExtractAccountFromPath(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"work/**", "work"},
		{"personal/**", "personal"},
		{"backup/*", "backup"},
		{"work/INBOX", "work"},
		{"work", "work"},
		{"", ""},
	}
	for _, tt := range tests {
		got := extractAccountFromPath(tt.input)
		if got != tt.want {
			t.Errorf("extractAccountFromPath(%q) = %q, want %q", tt.input, got, tt.want)
		}
	}
}

func TestSearch_MultiAccountOR(t *testing.T) {
	db := newTestDB(t)
	now := time.Now().Unix()

	db.InsertMessage(&Message{
		MessageID: "m1@x", Subject: "Work mail", FromAddr: "a@x",
		Date: now, CreatedAt: now, FetchedBody: true, Account: "work",
	})
	db.InsertMessage(&Message{
		MessageID: "m2@x", Subject: "Personal mail", FromAddr: "b@x",
		Date: now - 100, CreatedAt: now, FetchedBody: true, Account: "personal",
	})
	db.InsertMessage(&Message{
		MessageID: "m3@x", Subject: "Other mail", FromAddr: "c@x",
		Date: now - 200, CreatedAt: now, FetchedBody: true, Account: "other",
	})

	// Multi-account query: path:work/** OR path:personal/** should match work + personal
	results, err := db.Search("(path:work/** OR path:personal/**)", 10)
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	if len(results) != 2 {
		t.Errorf("got %d results for multi-account OR, want 2", len(results))
	}
}

func TestSearch_UnknownField(t *testing.T) {
	db := newTestDB(t)
	_, err := db.Search("unknown:value", 10)
	if err == nil {
		t.Error("expected error for unknown field")
	}
}
