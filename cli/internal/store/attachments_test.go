package store

import (
	"testing"
)

func TestInsertAndGetAttachments(t *testing.T) {
	db := newTestDB(t)
	msgID := insertTestMessage(t, db, "att@x")

	att := &Attachment{
		MessageDBID: msgID,
		PartID:      1,
		Filename:    "report.pdf",
		ContentType: "application/pdf",
		Size:        1024,
		Disposition: "attachment",
	}
	if err := db.InsertAttachment(att); err != nil {
		t.Fatalf("insert: %v", err)
	}
	if att.ID == 0 {
		t.Error("expected non-zero ID after insert")
	}

	atts, err := db.GetAttachmentsByMessage(msgID)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if len(atts) != 1 {
		t.Fatalf("got %d attachments, want 1", len(atts))
	}
	if atts[0].Filename != "report.pdf" {
		t.Errorf("Filename = %q, want %q", atts[0].Filename, "report.pdf")
	}
	if atts[0].ContentType != "application/pdf" {
		t.Errorf("ContentType = %q", atts[0].ContentType)
	}
	if atts[0].Size != 1024 {
		t.Errorf("Size = %d, want 1024", atts[0].Size)
	}
}

func TestGetAttachmentsByMessageID(t *testing.T) {
	db := newTestDB(t)
	msgID := insertTestMessage(t, db, "att-mid@x")

	db.InsertAttachment(&Attachment{
		MessageDBID: msgID, PartID: 1,
		Filename: "doc.txt", ContentType: "text/plain",
		Size: 100, Disposition: "attachment",
	})

	atts, err := db.GetAttachmentsByMessageID("att-mid@x")
	if err != nil {
		t.Fatalf("get by message ID: %v", err)
	}
	if len(atts) != 1 {
		t.Fatalf("got %d, want 1", len(atts))
	}
	if atts[0].Filename != "doc.txt" {
		t.Errorf("Filename = %q", atts[0].Filename)
	}
}

func TestGetAttachmentsByMessageIDNotFound(t *testing.T) {
	db := newTestDB(t)

	atts, err := db.GetAttachmentsByMessageID("nonexistent@x")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(atts) != 0 {
		t.Errorf("got %d attachments for nonexistent message", len(atts))
	}
}

func TestMultipleAttachments(t *testing.T) {
	db := newTestDB(t)
	msgID := insertTestMessage(t, db, "multi-att@x")

	db.InsertAttachment(&Attachment{
		MessageDBID: msgID, PartID: 1,
		Filename: "a.pdf", ContentType: "application/pdf",
		Size: 100, Disposition: "attachment",
	})
	db.InsertAttachment(&Attachment{
		MessageDBID: msgID, PartID: 2,
		Filename: "b.png", ContentType: "image/png",
		Size: 200, Disposition: "inline", ContentID: "cid:img1",
	})

	atts, _ := db.GetAttachmentsByMessage(msgID)
	if len(atts) != 2 {
		t.Fatalf("got %d, want 2", len(atts))
	}
	// Ordered by part_id
	if atts[0].PartID != 1 || atts[1].PartID != 2 {
		t.Error("attachments not ordered by part_id")
	}
	if atts[1].ContentID != "cid:img1" {
		t.Errorf("ContentID = %q, want %q", atts[1].ContentID, "cid:img1")
	}
	if atts[1].Disposition != "inline" {
		t.Errorf("Disposition = %q, want %q", atts[1].Disposition, "inline")
	}
}

func TestDeleteAttachmentsByMessageDBID(t *testing.T) {
	db := newTestDB(t)
	msgID := insertTestMessage(t, db, "del-att@x")

	db.InsertAttachment(&Attachment{
		MessageDBID: msgID, PartID: 1,
		Filename: "x.txt", ContentType: "text/plain",
	})
	db.InsertAttachment(&Attachment{
		MessageDBID: msgID, PartID: 2,
		Filename: "y.txt", ContentType: "text/plain",
	})

	err := db.DeleteAttachmentsByMessageDBID(msgID)
	if err != nil {
		t.Fatalf("delete: %v", err)
	}

	atts, _ := db.GetAttachmentsByMessage(msgID)
	if len(atts) != 0 {
		t.Errorf("got %d attachments after delete, want 0", len(atts))
	}
}

func TestDeleteAttachmentsCascade(t *testing.T) {
	db := newTestDB(t)
	msgID := insertTestMessage(t, db, "cascade@x")

	db.InsertAttachment(&Attachment{
		MessageDBID: msgID, PartID: 1,
		Filename: "z.txt", ContentType: "text/plain",
	})

	// Delete the message — attachments should cascade
	db.DeleteByMessageID("cascade@x")

	atts, _ := db.GetAttachmentsByMessage(msgID)
	if len(atts) != 0 {
		t.Errorf("attachments should be cascade-deleted, got %d", len(atts))
	}
}

func TestAttachmentCounts(t *testing.T) {
	db := newTestDB(t)
	id1 := insertTestMessage(t, db, "count1@x")
	id2 := insertTestMessage(t, db, "count2@x")
	insertTestMessage(t, db, "count3@x") // no attachments

	db.InsertAttachment(&Attachment{MessageDBID: id1, PartID: 1, Filename: "a.pdf"})
	db.InsertAttachment(&Attachment{MessageDBID: id1, PartID: 2, Filename: "b.pdf"})
	db.InsertAttachment(&Attachment{MessageDBID: id2, PartID: 1, Filename: "c.pdf"})

	counts, err := db.AttachmentCounts()
	if err != nil {
		t.Fatalf("counts: %v", err)
	}
	if counts[id1] != 2 {
		t.Errorf("msg1 count = %d, want 2", counts[id1])
	}
	if counts[id2] != 1 {
		t.Errorf("msg2 count = %d, want 1", counts[id2])
	}
}
