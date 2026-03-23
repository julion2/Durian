package smtp

import (
	"strings"
	"testing"
)

func TestMessageBuild(t *testing.T) {
	msg := &Message{
		From:    "sender@example.com",
		To:      []string{"recipient@example.com"},
		Subject: "Test Subject",
		Body:    "Hello, World!",
	}

	data, err := msg.Build()
	if err != nil {
		t.Fatalf("Build() error: %v", err)
	}

	content := string(data)

	// Check required headers
	requiredHeaders := []string{
		"From: sender@example.com",
		"To: recipient@example.com",
		"Subject: Test Subject",
		"MIME-Version: 1.0",
		"Content-Type: text/plain; charset=UTF-8",
	}

	for _, header := range requiredHeaders {
		if !strings.Contains(content, header) {
			t.Errorf("Missing header: %s\nContent:\n%s", header, content)
		}
	}

	// Check Message-ID present
	if !strings.Contains(content, "Message-ID: <") {
		t.Error("Missing Message-ID header")
	}

	// Check Date present
	if !strings.Contains(content, "Date: ") {
		t.Error("Missing Date header")
	}

	// Check body present
	if !strings.Contains(content, "Hello") {
		t.Error("Body not found in message")
	}
}

func TestMessageBuildWithAttachment(t *testing.T) {
	msg := &Message{
		From:    "sender@example.com",
		To:      []string{"recipient@example.com"},
		Subject: "Test with Attachment",
		Body:    "See attachment.",
		Attachments: []Attachment{
			{
				Filename: "test.txt",
				Data:     []byte("Hello from attachment!"),
				MIMEType: "text/plain",
			},
		},
	}

	data, err := msg.Build()
	if err != nil {
		t.Fatalf("Build() error: %v", err)
	}

	content := string(data)

	// Check multipart header
	if !strings.Contains(content, "Content-Type: multipart/mixed; boundary=") {
		t.Error("Missing multipart/mixed Content-Type")
	}

	// Check attachment present
	if !strings.Contains(content, "Content-Disposition: attachment; filename=\"test.txt\"") {
		t.Error("Missing attachment Content-Disposition")
	}
}

func TestMessageBuildHTML(t *testing.T) {
	msg := &Message{
		From:    "sender@example.com",
		To:      []string{"recipient@example.com"},
		Subject: "HTML Newsletter",
		Body:    "<html><body><h1>Hello!</h1><p>This is HTML content.</p></body></html>",
		IsHTML:  true,
	}

	data, err := msg.Build()
	if err != nil {
		t.Fatalf("Build() error: %v", err)
	}

	content := string(data)

	// Check for HTML content type
	if !strings.Contains(content, "Content-Type: text/html; charset=UTF-8") {
		t.Error("Missing text/html Content-Type")
	}

	// Should NOT have text/plain
	if strings.Contains(content, "Content-Type: text/plain") {
		t.Error("HTML message should not have text/plain Content-Type")
	}

	// Check body present
	if !strings.Contains(content, "<h1>Hello!</h1>") || !strings.Contains(content, "This is HTML content.") {
		t.Error("HTML body content not found in message")
	}
}

func TestMessageBuildHTMLWithAttachment(t *testing.T) {
	msg := &Message{
		From:    "sender@example.com",
		To:      []string{"recipient@example.com"},
		Subject: "HTML with Attachment",
		Body:    "<p>See attached file.</p>",
		IsHTML:  true,
		Attachments: []Attachment{
			{
				Filename: "doc.pdf",
				Data:     []byte("fake pdf content"),
				MIMEType: "application/pdf",
			},
		},
	}

	data, err := msg.Build()
	if err != nil {
		t.Fatalf("Build() error: %v", err)
	}

	content := string(data)

	// Check multipart header
	if !strings.Contains(content, "Content-Type: multipart/mixed; boundary=") {
		t.Error("Missing multipart/mixed Content-Type")
	}

	// Check HTML content type for body part
	if !strings.Contains(content, "Content-Type: text/html; charset=UTF-8") {
		t.Error("Missing text/html Content-Type for body part")
	}

	// Check attachment
	if !strings.Contains(content, "Content-Disposition: attachment; filename=\"doc.pdf\"") {
		t.Error("Missing attachment Content-Disposition")
	}
}

func TestMessageBuildUTF8Subject(t *testing.T) {
	msg := &Message{
		From:    "sender@example.com",
		To:      []string{"recipient@example.com"},
		Subject: "Test mit Umlauten: äöü",
		Body:    "Hello!",
	}

	data, err := msg.Build()
	if err != nil {
		t.Fatalf("Build() error: %v", err)
	}

	content := string(data)

	// Subject should be encoded (RFC 2047)
	if strings.Contains(content, "Subject: Test mit Umlauten: äöü\r\n") {
		t.Error("UTF-8 subject should be encoded")
	}
	if !strings.Contains(content, "Subject: =?UTF-8?") {
		t.Error("Subject should be RFC 2047 encoded")
	}
}

func TestParseAddress(t *testing.T) {
	tests := []struct {
		input   string
		want    string
		wantErr bool
	}{
		{"test@example.com", "test@example.com", false},
		{"  test@example.com  ", "test@example.com", false},
		{"Test User <test@example.com>", "test@example.com", false},
		{"\"Test User\" <test@example.com>", "test@example.com", false},
		{"", "", true},
		{"not-an-email", "", true},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			got, err := ParseAddress(tt.input)
			if (err != nil) != tt.wantErr {
				t.Errorf("ParseAddress(%q) error = %v, wantErr %v", tt.input, err, tt.wantErr)
				return
			}
			if !tt.wantErr && got != tt.want {
				t.Errorf("ParseAddress(%q) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}

func TestParseAddressList(t *testing.T) {
	tests := []struct {
		input   string
		want    []string
		wantErr bool
	}{
		{"a@example.com", []string{"a@example.com"}, false},
		{"a@example.com,b@example.com", []string{"a@example.com", "b@example.com"}, false},
		{"a@example.com, b@example.com , c@example.com", []string{"a@example.com", "b@example.com", "c@example.com"}, false},
		{"", nil, false},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			got, err := ParseAddressList(tt.input)
			if (err != nil) != tt.wantErr {
				t.Errorf("ParseAddressList(%q) error = %v, wantErr %v", tt.input, err, tt.wantErr)
				return
			}
			if !tt.wantErr {
				if len(got) != len(tt.want) {
					t.Errorf("ParseAddressList(%q) = %v, want %v", tt.input, got, tt.want)
					return
				}
				for i, addr := range got {
					if addr != tt.want[i] {
						t.Errorf("ParseAddressList(%q)[%d] = %q, want %q", tt.input, i, addr, tt.want[i])
					}
				}
			}
		})
	}
}

func TestReadBody(t *testing.T) {
	input := `Hello World!

This is a test message.

# This is a comment
# And another comment

End of message.`

	body, err := ReadBody(strings.NewReader(input))
	if err != nil {
		t.Fatalf("ReadBody() error: %v", err)
	}

	// Should not contain comment lines
	if strings.Contains(body, "# This is a comment") {
		t.Error("Body should not contain comment lines")
	}

	// Should contain actual content
	if !strings.Contains(body, "Hello World!") {
		t.Error("Body missing 'Hello World!'")
	}
	if !strings.Contains(body, "End of message.") {
		t.Error("Body missing 'End of message.'")
	}
}

func TestLoadAttachment(t *testing.T) {
	// Test loading non-existent file
	_, err := LoadAttachment("/nonexistent/file.pdf")
	if err == nil {
		t.Error("LoadAttachment() should fail for non-existent file")
	}
}

func TestOAuth2AuthCredentials(t *testing.T) {
	auth := &OAuth2Auth{
		Email:       "test@example.com",
		AccessToken: "token123",
	}

	if auth.Method() != "XOAUTH2" {
		t.Errorf("Method() = %q, want %q", auth.Method(), "XOAUTH2")
	}

	creds, err := auth.Credentials("")
	if err != nil {
		t.Fatalf("Credentials() error: %v", err)
	}

	expected := "user=test@example.com\x01auth=Bearer token123\x01\x01"
	if string(creds) != expected {
		t.Errorf("Credentials() = %q, want %q", string(creds), expected)
	}
}

func TestPasswordAuthCredentials(t *testing.T) {
	auth := &PasswordAuth{
		Username: "user",
		Password: "pass",
	}

	if auth.Method() != "PLAIN" {
		t.Errorf("Method() = %q, want %q", auth.Method(), "PLAIN")
	}

	creds, err := auth.Credentials("")
	if err != nil {
		t.Fatalf("Credentials() error: %v", err)
	}

	expected := "\x00user\x00pass"
	if string(creds) != expected {
		t.Errorf("Credentials() = %q, want %q", string(creds), expected)
	}
}

func TestRecipients(t *testing.T) {
	msg := &Message{
		From: "sender@example.com",
		To:   []string{"a@example.com", "b@example.com"},
	}

	recipients := msg.Recipients()
	if len(recipients) != 2 {
		t.Errorf("Recipients() length = %d, want 2", len(recipients))
	}
}
