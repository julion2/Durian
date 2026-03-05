package mail

import (
	"net/mail"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func loadTestMail(t *testing.T, filename string) *mail.Message {
	t.Helper()

	path := filepath.Join("testdata", filename)
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("Failed to open test file %s: %v", filename, err)
	}
	defer f.Close()

	msg, err := mail.ReadMessage(f)
	if err != nil {
		t.Fatalf("Failed to parse test file %s: %v", filename, err)
	}

	return msg
}

func TestParserSimpleText(t *testing.T) {
	msg := loadTestMail(t, "simple_text.eml")
	parser := NewParser()

	content := parser.Parse(msg)

	// Check headers
	if content.From != "sender@example.com" {
		t.Errorf("From = %q, want %q", content.From, "sender@example.com")
	}
	if content.To != "recipient@example.com" {
		t.Errorf("To = %q, want %q", content.To, "recipient@example.com")
	}
	if content.Subject != "Simple Text Email" {
		t.Errorf("Subject = %q, want %q", content.Subject, "Simple Text Email")
	}
	if !strings.Contains(content.Date, "18 Dec 2025") {
		t.Errorf("Date = %q, should contain '18 Dec 2025'", content.Date)
	}

	// Check body
	if !strings.Contains(content.Body, "Hello, this is a simple text email") {
		t.Errorf("Body should contain text content, got: %q", content.Body)
	}
	if !strings.Contains(content.Body, "Best regards") {
		t.Errorf("Body should contain 'Best regards', got: %q", content.Body)
	}

	// HTML should be empty for plain text
	if content.HTML != "" {
		t.Errorf("HTML should be empty for plain text email, got: %q", content.HTML)
	}

	// No attachments
	if len(content.Attachments) != 0 {
		t.Errorf("Attachments should be empty, got: %v", content.Attachments)
	}
}

func TestParserSimpleHTML(t *testing.T) {
	msg := loadTestMail(t, "simple_html.eml")
	parser := NewParser()

	content := parser.Parse(msg)

	// Check headers
	if content.Subject != "Simple HTML Email" {
		t.Errorf("Subject = %q, want %q", content.Subject, "Simple HTML Email")
	}

	// HTML should contain the original HTML
	if !strings.Contains(content.HTML, "<h1>Hello World</h1>") {
		t.Errorf("HTML should contain h1 tag, got: %q", content.HTML)
	}
	if !strings.Contains(content.HTML, "<strong>HTML</strong>") {
		t.Errorf("HTML should contain strong tag, got: %q", content.HTML)
	}

	// Body should be stripped text (either from w3m or fallback)
	if !strings.Contains(content.Body, "Hello World") {
		t.Errorf("Body should contain 'Hello World', got: %q", content.Body)
	}
}

func TestParserMultipartAlternative(t *testing.T) {
	msg := loadTestMail(t, "multipart_alternative.eml")
	parser := NewParser()

	content := parser.Parse(msg)

	// Check headers
	if content.Subject != "Multipart Alternative Email" {
		t.Errorf("Subject = %q, want %q", content.Subject, "Multipart Alternative Email")
	}

	// Body should be from text/plain part
	if !strings.Contains(content.Body, "This is the plain text version") {
		t.Errorf("Body should contain plain text content, got: %q", content.Body)
	}

	// HTML should be from text/html part
	if !strings.Contains(content.HTML, "<strong>HTML</strong>") {
		t.Errorf("HTML should contain HTML content, got: %q", content.HTML)
	}

	// No attachments
	if len(content.Attachments) != 0 {
		t.Errorf("Attachments should be empty, got: %v", content.Attachments)
	}
}

func TestParserMultipartWithAttachment(t *testing.T) {
	msg := loadTestMail(t, "multipart_with_attachment.eml")
	parser := NewParser()

	content := parser.Parse(msg)

	// Check headers
	if content.Subject != "Email with Attachment" {
		t.Errorf("Subject = %q, want %q", content.Subject, "Email with Attachment")
	}

	// Body should contain text
	if !strings.Contains(content.Body, "This email has an attachment") {
		t.Errorf("Body should contain text content, got: %q", content.Body)
	}

	// Should have 2 attachments
	if len(content.Attachments) != 2 {
		t.Errorf("Should have 2 attachments, got: %v", content.Attachments)
	}

	// Check attachment names
	hasDocument := false
	hasImage := false
	for _, att := range content.Attachments {
		if att.Filename == "document.pdf" {
			hasDocument = true
		}
		if att.Filename == "image.png" {
			hasImage = true
		}
	}
	if !hasDocument {
		t.Error("Should have document.pdf attachment")
	}
	if !hasImage {
		t.Error("Should have image.png attachment")
	}
}

func TestParserEncodedHeaders(t *testing.T) {
	msg := loadTestMail(t, "encoded_headers.eml")
	parser := NewParser()

	content := parser.Parse(msg)

	// From should be decoded
	if !strings.Contains(content.From, "Thomas Müller") {
		t.Errorf("From should contain 'Thomas Müller', got: %q", content.From)
	}
	if !strings.Contains(content.From, "mueller@example.com") {
		t.Errorf("From should contain email address, got: %q", content.From)
	}

	// To should be decoded (Base64 encoded "Schröder")
	if !strings.Contains(content.To, "Schröder") {
		t.Errorf("To should contain 'Schröder', got: %q", content.To)
	}

	// Subject should be decoded
	if !strings.Contains(content.Subject, "Grüße aus München") {
		t.Errorf("Subject should contain 'Grüße aus München', got: %q", content.Subject)
	}

	// Body should be decoded from quoted-printable
	if !strings.Contains(content.Body, "Schöne Grüße") {
		t.Errorf("Body should contain 'Schöne Grüße', got: %q", content.Body)
	}
}

func TestParserBase64Body(t *testing.T) {
	msg := loadTestMail(t, "base64_body.eml")
	parser := NewParser()

	content := parser.Parse(msg)

	// Check subject
	if content.Subject != "Base64 Encoded Body" {
		t.Errorf("Subject = %q, want %q", content.Subject, "Base64 Encoded Body")
	}

	// Body should be decoded from base64
	if !strings.Contains(content.Body, "Hello, this is a base64 encoded email body") {
		t.Errorf("Body should contain decoded text, got: %q", content.Body)
	}
	if !strings.Contains(content.Body, "Best regards") {
		t.Errorf("Body should contain 'Best regards', got: %q", content.Body)
	}
}

func TestParserISO88591(t *testing.T) {
	msg := loadTestMail(t, "iso88591.eml")
	parser := NewParser()

	content := parser.Parse(msg)

	// Check subject
	if content.Subject != "ISO-8859-1 Email" {
		t.Errorf("Subject = %q, want %q", content.Subject, "ISO-8859-1 Email")
	}

	// Body should be converted from ISO-8859-1 to UTF-8
	if !strings.Contains(content.Body, "Grüße aus Deutschland") {
		t.Errorf("Body should contain 'Grüße aus Deutschland', got: %q", content.Body)
	}
	if !strings.Contains(content.Body, "äöüß") {
		t.Errorf("Body should contain 'äöüß', got: %q", content.Body)
	}
}

func TestNewParser(t *testing.T) {
	parser := NewParser()
	if parser == nil {
		t.Error("NewParser() should not return nil")
	}
}
