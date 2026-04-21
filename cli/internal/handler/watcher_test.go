package handler

import (
	"strings"
	"sync"
	"testing"

	goImap "github.com/emersion/go-imap"
)

// --- cleanSnippet ---

func TestCleanSnippet_StripsSignature(t *testing.T) {
	body := "Hello world!\n\n-- \nBest,\nAlice"
	got := cleanSnippet(body, 200)
	if strings.Contains(got, "Best") || strings.Contains(got, "--") {
		t.Errorf("signature not stripped: %q", got)
	}
	if !strings.Contains(got, "Hello world") {
		t.Errorf("body lost: %q", got)
	}
}

func TestCleanSnippet_StripsQuotedLines(t *testing.T) {
	body := "My reply\n> previous line 1\n> previous line 2\nmore reply"
	got := cleanSnippet(body, 200)
	if strings.Contains(got, "previous") {
		t.Errorf("quoted content not stripped: %q", got)
	}
	if !strings.Contains(got, "My reply") || !strings.Contains(got, "more reply") {
		t.Errorf("non-quoted content lost: %q", got)
	}
}

func TestCleanSnippet_CollapsesWhitespace(t *testing.T) {
	body := "Line one\n\n\nLine two\n\nLine three"
	got := cleanSnippet(body, 200)
	if strings.Contains(got, "\n") {
		t.Errorf("newlines not collapsed: %q", got)
	}
	if got != "Line one Line two Line three" {
		t.Errorf("got %q, want %q", got, "Line one Line two Line three")
	}
}

func TestCleanSnippet_TruncatesAtWordBoundary(t *testing.T) {
	body := "The quick brown fox jumps over the lazy dog repeatedly every day"
	got := cleanSnippet(body, 25)
	if !strings.HasSuffix(got, "…") {
		t.Errorf("truncation marker missing: %q", got)
	}
	if len(got) > 30 {
		t.Errorf("result too long: %q (len %d)", got, len(got))
	}
	// Must end at a space boundary, not mid-word
	withoutMarker := strings.TrimSuffix(got, "…")
	if strings.HasSuffix(withoutMarker, "qui") || strings.HasSuffix(withoutMarker, "fo") {
		t.Errorf("truncated mid-word: %q", got)
	}
}

func TestCleanSnippet_ShortInputUnchanged(t *testing.T) {
	body := "Hi there"
	got := cleanSnippet(body, 100)
	if got != "Hi there" {
		t.Errorf("got %q, want %q", got, "Hi there")
	}
}

func TestCleanSnippet_EmptyInput(t *testing.T) {
	if got := cleanSnippet("", 100); got != "" {
		t.Errorf("empty input: got %q, want \"\"", got)
	}
}

// --- isAttachmentLike ---

func TestIsAttachmentLike_ExplicitDisposition(t *testing.T) {
	bs := &goImap.BodyStructure{Disposition: "attachment"}
	if !isAttachmentLike(bs) {
		t.Error("explicit attachment disposition not detected")
	}
}

func TestIsAttachmentLike_DispositionParamsFilename(t *testing.T) {
	bs := &goImap.BodyStructure{
		MIMEType:          "application",
		MIMESubType:       "pdf",
		DispositionParams: map[string]string{"filename": "report.pdf"},
	}
	if !isAttachmentLike(bs) {
		t.Error("filename in disposition params not detected")
	}
}

func TestIsAttachmentLike_ParamsName(t *testing.T) {
	bs := &goImap.BodyStructure{
		MIMEType: "image",
		Params:   map[string]string{"name": "photo.jpg"},
	}
	if !isAttachmentLike(bs) {
		t.Error("name in params not detected")
	}
}

func TestIsAttachmentLike_TextPartWithNameNotAttachment(t *testing.T) {
	// A text/plain part with just a name shouldn't count as attachment
	bs := &goImap.BodyStructure{
		MIMEType: "text",
		Params:   map[string]string{"name": "inline.txt"},
	}
	if isAttachmentLike(bs) {
		t.Error("text part with name incorrectly flagged as attachment")
	}
}

func TestIsAttachmentLike_NoDispositionNoName(t *testing.T) {
	bs := &goImap.BodyStructure{MIMEType: "text", MIMESubType: "plain"}
	if isAttachmentLike(bs) {
		t.Error("bare text part flagged as attachment")
	}
}

// --- walkForFilename ---
//
// Note: walkForFilename returns `prefix` (the accumulated path) when a leaf
// matches. Called with prefix=nil and a top-level leaf, it returns a nil
// path — which findAttachmentSection then treats as "no filename match,
// fall through to index lookup". Tests below always use multipart roots so
// the returned path is non-nil when a match occurs.

func TestWalkForFilename_NestedMultipart(t *testing.T) {
	// multipart/mixed                   -> root
	//   [1] text/plain
	//   [2] multipart/alternative
	//     [2,1] text/plain
	//     [2,2] application/pdf report.pdf
	bs := &goImap.BodyStructure{
		MIMEType:    "multipart",
		MIMESubType: "mixed",
		Parts: []*goImap.BodyStructure{
			{MIMEType: "text", MIMESubType: "plain"},
			{
				MIMEType:    "multipart",
				MIMESubType: "alternative",
				Parts: []*goImap.BodyStructure{
					{MIMEType: "text", MIMESubType: "plain"},
					{
						MIMEType:          "application",
						MIMESubType:       "pdf",
						DispositionParams: map[string]string{"filename": "report.pdf"},
						Encoding:          "base64",
					},
				},
			},
		},
	}
	path, enc := walkForFilename(bs, "report.pdf", nil)
	if len(path) != 2 || path[0] != 2 || path[1] != 2 {
		t.Errorf("path = %v, want [2 2]", path)
	}
	if enc != "base64" {
		t.Errorf("encoding = %q", enc)
	}
}

func TestWalkForFilename_CaseInsensitive(t *testing.T) {
	// Wrap the leaf in a multipart so walkForFilename returns a non-nil
	// path on match (see note above).
	bs := &goImap.BodyStructure{
		MIMEType:    "multipart",
		MIMESubType: "mixed",
		Parts: []*goImap.BodyStructure{
			{
				MIMEType:          "application",
				MIMESubType:       "pdf",
				DispositionParams: map[string]string{"filename": "Report.PDF"},
				Encoding:          "base64",
			},
		},
	}
	path, _ := walkForFilename(bs, "report.pdf", nil)
	if len(path) != 1 || path[0] != 1 {
		t.Errorf("case-insensitive match: path = %v, want [1]", path)
	}
}

func TestWalkForFilename_NoMatch(t *testing.T) {
	bs := &goImap.BodyStructure{
		MIMEType:          "application",
		MIMESubType:       "pdf",
		DispositionParams: map[string]string{"filename": "other.pdf"},
	}
	path, _ := walkForFilename(bs, "missing.pdf", nil)
	if path != nil {
		t.Errorf("unexpected match: %v", path)
	}
}

// --- walkForIndex ---

func TestWalkForIndex_SkipsTextParts(t *testing.T) {
	// multipart/mixed
	//   text/plain
	//   application/pdf (1st attachment)
	//   image/png (2nd attachment)
	bs := &goImap.BodyStructure{
		MIMEType:    "multipart",
		MIMESubType: "mixed",
		Parts: []*goImap.BodyStructure{
			{MIMEType: "text", MIMESubType: "plain"},
			{
				MIMEType:          "application",
				MIMESubType:       "pdf",
				DispositionParams: map[string]string{"filename": "a.pdf"},
				Encoding:          "base64",
			},
			{
				MIMEType:    "image",
				MIMESubType: "png",
				Params:      map[string]string{"name": "b.png"},
				Encoding:    "base64",
			},
		},
	}

	counter := 0
	path, _ := walkForIndex(bs, 1, &counter, nil)
	if len(path) != 1 || path[0] != 2 {
		t.Errorf("1st attachment path = %v, want [2]", path)
	}

	counter = 0
	path, _ = walkForIndex(bs, 2, &counter, nil)
	if len(path) != 1 || path[0] != 3 {
		t.Errorf("2nd attachment path = %v, want [3]", path)
	}
}

func TestWalkForIndex_IndexOutOfRange(t *testing.T) {
	bs := &goImap.BodyStructure{
		MIMEType:          "application",
		MIMESubType:       "pdf",
		DispositionParams: map[string]string{"filename": "a.pdf"},
	}
	counter := 0
	path, _ := walkForIndex(bs, 5, &counter, nil)
	if path != nil {
		t.Errorf("expected nil for out-of-range index, got %v", path)
	}
}

// --- findAttachmentSection ---

func TestFindAttachmentSection_FilenameFirst(t *testing.T) {
	// Filename "b.pdf" should match even though it's the 2nd attachment
	// (filename lookup takes precedence over index fallback).
	bs := &goImap.BodyStructure{
		MIMEType:    "multipart",
		MIMESubType: "mixed",
		Parts: []*goImap.BodyStructure{
			{
				MIMEType:          "application",
				MIMESubType:       "pdf",
				DispositionParams: map[string]string{"filename": "a.pdf"},
				Encoding:          "base64",
			},
			{
				MIMEType:          "application",
				MIMESubType:       "pdf",
				DispositionParams: map[string]string{"filename": "b.pdf"},
				Encoding:          "base64",
			},
		},
	}
	path, _ := findAttachmentSection(bs, "b.pdf", 99)
	if len(path) != 1 || path[0] != 2 {
		t.Errorf("path = %v, want [2]", path)
	}
}

func TestFindAttachmentSection_IndexFallback(t *testing.T) {
	// Wrong filename, but index=1 still resolves to first attachment.
	bs := &goImap.BodyStructure{
		MIMEType:    "multipart",
		MIMESubType: "mixed",
		Parts: []*goImap.BodyStructure{
			{
				MIMEType:          "application",
				MIMESubType:       "pdf",
				DispositionParams: map[string]string{"filename": "a.pdf"},
				Encoding:          "base64",
			},
		},
	}
	path, _ := findAttachmentSection(bs, "does-not-exist.pdf", 1)
	if len(path) != 1 || path[0] != 1 {
		t.Errorf("path = %v, want [1]", path)
	}
}

func TestFindAttachmentSection_NoMatch(t *testing.T) {
	bs := &goImap.BodyStructure{
		MIMEType:    "text",
		MIMESubType: "plain",
	}
	path, enc := findAttachmentSection(bs, "a.pdf", 1)
	if path != nil || enc != "" {
		t.Errorf("expected no match, got path=%v enc=%q", path, enc)
	}
}

// --- WatcherManager construction ---

func TestNewWatcherManager(t *testing.T) {
	db := newTestStore(t)
	w := NewWatcherManager(nil, db, nil, nil)
	if w == nil {
		t.Fatal("nil watcher manager")
	}
	if w.store != db {
		t.Error("store not stored")
	}
	if w.locks == nil || w.watchers == nil {
		t.Error("maps not initialized")
	}
	if w.log == nil {
		t.Error("logger not set")
	}
}

func TestWatcherManager_AccountLock_SameEmailSameLock(t *testing.T) {
	db := newTestStore(t)
	w := NewWatcherManager(nil, db, nil, nil)

	a := w.accountLock("alice@example.com")
	b := w.accountLock("alice@example.com")
	if a != b {
		t.Error("accountLock returned different locks for same email")
	}
}

func TestWatcherManager_AccountLock_DifferentEmailsDifferentLocks(t *testing.T) {
	db := newTestStore(t)
	w := NewWatcherManager(nil, db, nil, nil)

	a := w.accountLock("alice@example.com")
	b := w.accountLock("bob@example.com")
	if a == b {
		t.Error("accountLock returned same lock for different emails")
	}
}

func TestWatcherManager_AccountLock_ConcurrentSafe(t *testing.T) {
	db := newTestStore(t)
	w := NewWatcherManager(nil, db, nil, nil)

	// Hammer accountLock from multiple goroutines — should not race
	// when run under `bazel test --test_arg=-race` (go_test has race
	// detection on by default in bazel rules_go).
	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_ = w.accountLock("alice@example.com")
			_ = w.accountLock("bob@example.com")
		}()
	}
	wg.Wait()

	// Should have exactly 2 locks after the storm
	if len(w.locks) != 2 {
		t.Errorf("got %d locks, want 2", len(w.locks))
	}
}

func TestWatcherManager_TriggerSync_UnknownAccount(t *testing.T) {
	db := newTestStore(t)
	w := NewWatcherManager(nil, db, nil, nil)

	// Must not panic when the account has no registered watcher
	w.TriggerSync("unknown-account")
}
