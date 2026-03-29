package imap

import (
	"testing"

	imap "github.com/emersion/go-imap"
)

func TestGmailLabelsToTags_SystemLabels(t *testing.T) {
	msg := &imap.Message{
		Items: map[imap.FetchItem]interface{}{
			"X-GM-LABELS": []interface{}{"\\Inbox", "\\Sent", "\\Starred", "\\Important"},
		},
	}

	tags := gmailLabelsToTags(msg)
	want := map[string]bool{"inbox": true, "sent": true, "flagged": true, "important": true}

	for _, tag := range tags {
		if !want[tag] {
			t.Errorf("unexpected tag: %q", tag)
		}
		delete(want, tag)
	}
	for tag := range want {
		t.Errorf("missing tag: %q", tag)
	}
}

func TestGmailLabelsToTags_UserLabels(t *testing.T) {
	msg := &imap.Message{
		Items: map[imap.FetchItem]interface{}{
			"X-GM-LABELS": []interface{}{"Orders", "Finance Briefing", "blind-sonar"},
		},
	}

	tags := gmailLabelsToTags(msg)
	want := map[string]bool{"orders": true, "finance-briefing": true, "blind-sonar": true}

	for _, tag := range tags {
		if !want[tag] {
			t.Errorf("unexpected tag: %q", tag)
		}
		delete(want, tag)
	}
	for tag := range want {
		t.Errorf("missing tag: %q", tag)
	}
}

func TestGmailLabelsToTags_IgnoredLabels(t *testing.T) {
	msg := &imap.Message{
		Items: map[imap.FetchItem]interface{}{
			"X-GM-LABELS": []interface{}{
				"CATEGORY_PERSONAL", "CATEGORY_SOCIAL",
				"CATEGORY_PROMOTIONS", "CATEGORY_UPDATES", "CATEGORY_FORUMS",
			},
		},
	}

	tags := gmailLabelsToTags(msg)
	if len(tags) != 0 {
		t.Errorf("expected no tags for categories, got %v", tags)
	}
}

func TestGmailLabelsToTags_SpamTrash(t *testing.T) {
	msg := &imap.Message{
		Items: map[imap.FetchItem]interface{}{
			"X-GM-LABELS": []interface{}{"\\Trash", "\\Spam"},
		},
	}

	tags := gmailLabelsToTags(msg)
	want := map[string]bool{"trash": true, "spam": true}

	for _, tag := range tags {
		if !want[tag] {
			t.Errorf("unexpected tag: %q", tag)
		}
	}
}

func TestGmailLabelsToTags_NoLabels(t *testing.T) {
	msg := &imap.Message{
		Items: map[imap.FetchItem]interface{}{},
	}

	tags := gmailLabelsToTags(msg)
	if len(tags) != 0 {
		t.Errorf("expected no tags, got %v", tags)
	}
}

func TestGmailLabelsToTags_NilItems(t *testing.T) {
	msg := &imap.Message{}
	tags := gmailLabelsToTags(msg)
	if len(tags) != 0 {
		t.Errorf("expected no tags, got %v", tags)
	}
}

func TestGmailLabelsToTags_QuotedLabels(t *testing.T) {
	msg := &imap.Message{
		Items: map[imap.FetchItem]interface{}{
			"X-GM-LABELS": []interface{}{`"My Projects"`, `"Work/Important"`},
		},
	}

	tags := gmailLabelsToTags(msg)
	found := make(map[string]bool)
	for _, tag := range tags {
		found[tag] = true
	}
	if !found["my-projects"] {
		t.Error("missing tag my-projects")
	}
	if !found["work/important"] {
		t.Error("missing tag work/important")
	}
}

func TestGmailLabelsToTags_Mixed(t *testing.T) {
	msg := &imap.Message{
		Items: map[imap.FetchItem]interface{}{
			"X-GM-LABELS": []interface{}{
				"\\Inbox", "\\Important", "CATEGORY_PERSONAL", "Newsletter",
			},
		},
	}

	tags := gmailLabelsToTags(msg)
	found := make(map[string]bool)
	for _, tag := range tags {
		found[tag] = true
	}

	if !found["inbox"] {
		t.Error("missing inbox")
	}
	if !found["important"] {
		t.Error("missing important")
	}
	if !found["newsletter"] {
		t.Error("missing newsletter")
	}
	if found["category_personal"] {
		t.Error("CATEGORY_PERSONAL should be ignored")
	}
	if len(tags) != 3 {
		t.Errorf("expected 3 tags, got %d: %v", len(tags), tags)
	}
}
