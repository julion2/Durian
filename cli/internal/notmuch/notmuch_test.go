package notmuch

import (
	"encoding/json"
	"testing"

	internmail "github.com/durian-dev/durian/cli/internal/mail"
)

func TestParseFilenames(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected []string
	}{
		{
			name:     "single file",
			input:    "/home/user/.mail/account/INBOX/cur/1234567890.abc:2,S\n",
			expected: []string{"/home/user/.mail/account/INBOX/cur/1234567890.abc:2,S"},
		},
		{
			name:  "multiple files",
			input: "/home/user/.mail/account/INBOX/cur/1234567890.abc:2,S\n/home/user/.mail/account/Sent/cur/1234567890.abc:2,S\n",
			expected: []string{
				"/home/user/.mail/account/INBOX/cur/1234567890.abc:2,S",
				"/home/user/.mail/account/Sent/cur/1234567890.abc:2,S",
			},
		},
		{
			name:     "empty output",
			input:    "",
			expected: nil,
		},
		{
			name:     "whitespace only",
			input:    "  \n  \n",
			expected: nil,
		},
		{
			name:     "trailing newline",
			input:    "/path/to/file\n",
			expected: []string{"/path/to/file"},
		},
		{
			name:  "blank lines between files",
			input: "/path/one\n\n/path/two\n",
			expected: []string{
				"/path/one",
				"/path/two",
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := parseFilenames(tt.input)
			if len(got) != len(tt.expected) {
				t.Errorf("parseFilenames() = %v (len %d), want %v (len %d)", got, len(got), tt.expected, len(tt.expected))
				return
			}
			for i, f := range got {
				if f != tt.expected[i] {
					t.Errorf("parseFilenames()[%d] = %q, want %q", i, f, tt.expected[i])
				}
			}
		})
	}
}

func TestExtractBodyContent(t *testing.T) {
	tests := []struct {
		name            string
		body            string // JSON array of body parts
		wantText        string
		wantHTML        string
		wantAttachments []internmail.AttachmentInfo
	}{
		{
			name:     "text/plain only",
			body:     `[{"id": 1, "content-type": "text/plain", "content": "Hello world"}]`,
			wantText: "Hello world",
		},
		{
			name:     "text/html only",
			body:     `[{"id": 1, "content-type": "text/html", "content": "<p>Hello</p>"}]`,
			wantHTML: "<p>Hello</p>",
		},
		{
			name: "multipart/alternative with text and html",
			body: `[{"id": 1, "content-type": "multipart/alternative", "content": [
				{"id": 2, "content-type": "text/plain", "content": "plain text"},
				{"id": 3, "content-type": "text/html", "content": "<p>html text</p>"}
			]}]`,
			wantText: "plain text",
			wantHTML: "<p>html text</p>",
		},
		{
			name: "attachment",
			body: `[
				{"id": 1, "content-type": "text/plain", "content": "See attached"},
				{"id": 2, "content-type": "application/pdf", "content-disposition": "attachment", "content-length": 12345, "filename": "report.pdf"}
			]`,
			wantText: "See attached",
			wantAttachments: []internmail.AttachmentInfo{
				{PartID: 2, Filename: "report.pdf", ContentType: "application/pdf", Size: 12345, Disposition: "attachment"},
			},
		},
		{
			name: "nested multipart with attachment",
			body: `[{"id": 1, "content-type": "multipart/mixed", "content": [
				{"id": 2, "content-type": "multipart/alternative", "content": [
					{"id": 3, "content-type": "text/plain", "content": "body text"},
					{"id": 4, "content-type": "text/html", "content": "<p>body html</p>"}
				]},
				{"id": 5, "content-type": "image/png", "content-disposition": "attachment", "content-length": 9999, "filename": "screenshot.png"}
			]}]`,
			wantText: "body text",
			wantHTML: "<p>body html</p>",
			wantAttachments: []internmail.AttachmentInfo{
				{PartID: 5, Filename: "screenshot.png", ContentType: "image/png", Size: 9999, Disposition: "attachment"},
			},
		},
		{
			name: "inline attachment with content-id",
			body: `[
				{"id": 1, "content-type": "text/html", "content": "<p>See image below</p>"},
				{"id": 2, "content-type": "image/jpeg", "content-disposition": "inline", "content-id": "img001@mail", "content-length": 5000, "filename": "photo.jpg"}
			]`,
			wantHTML: "<p>See image below</p>",
			wantAttachments: []internmail.AttachmentInfo{
				{PartID: 2, Filename: "photo.jpg", ContentType: "image/jpeg", Size: 5000, Disposition: "inline", ContentID: "img001@mail"},
			},
		},
		{
			name: "filename without disposition defaults to attachment",
			body: `[
				{"id": 1, "content-type": "text/plain", "content": "Here is a file"},
				{"id": 2, "content-type": "application/zip", "filename": "archive.zip", "content-length": 2048}
			]`,
			wantText: "Here is a file",
			wantAttachments: []internmail.AttachmentInfo{
				{PartID: 2, Filename: "archive.zip", ContentType: "application/zip", Size: 2048, Disposition: "attachment"},
			},
		},
		{
			name: "empty body",
			body: `[]`,
		},
		{
			name:     "first text/plain wins",
			body:     `[{"id": 1, "content-type": "text/plain", "content": "first"}, {"id": 2, "content-type": "text/plain", "content": "second"}]`,
			wantText: "first",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var body []json.RawMessage
			if err := json.Unmarshal([]byte(tt.body), &body); err != nil {
				t.Fatalf("invalid test body JSON: %v", err)
			}

			gotText, gotHTML, gotAttachments := ExtractBodyContent(body)

			if gotText != tt.wantText {
				t.Errorf("text = %q, want %q", gotText, tt.wantText)
			}
			if gotHTML != tt.wantHTML {
				t.Errorf("html = %q, want %q", gotHTML, tt.wantHTML)
			}
			if len(gotAttachments) != len(tt.wantAttachments) {
				t.Errorf("attachments count = %d, want %d: %v", len(gotAttachments), len(tt.wantAttachments), gotAttachments)
			} else {
				for i, a := range gotAttachments {
					want := tt.wantAttachments[i]
					if a.PartID != want.PartID || a.Filename != want.Filename ||
						a.ContentType != want.ContentType || a.Size != want.Size ||
						a.Disposition != want.Disposition || a.ContentID != want.ContentID {
						t.Errorf("attachment[%d] = %+v, want %+v", i, a, want)
					}
				}
			}
		})
	}
}

func TestStripQuotedContent(t *testing.T) {
	tests := []struct {
		name string
		html string
		want string
	}{
		{
			name: "empty string",
			html: "",
			want: "",
		},
		{
			name: "no quoted content",
			html: "<p>Hello world</p>",
			want: "<p>Hello world</p>",
		},
		{
			name: "Gmail quote",
			html: `<p>My reply</p><div class="gmail_quote"><p>Original message</p></div>`,
			want: `<p>My reply</p>`,
		},
		{
			name: "Gmail blockquote",
			html: `<p>Reply</p><blockquote class="gmail_quote"><p>Quoted</p></blockquote>`,
			want: `<p>Reply</p>`,
		},
		{
			name: "Outlook divRplyFwdMsg",
			html: `<p>My response</p><div id="divRplyFwdMsg"><p>Original</p></div>`,
			want: `<p>My response</p>`,
		},
		{
			name: "Outlook appendonsend",
			html: `<p>Top text</p><div id="appendonsend"><p>Below</p></div>`,
			want: `<p>Top text</p>`,
		},
		{
			name: "Apple Mail blockquote type=cite",
			html: `<p>Response</p><blockquote type="cite"><p>Original</p></blockquote>`,
			want: `<p>Response</p>`,
		},
		{
			name: "generic blockquote",
			html: `<p>Reply</p><blockquote><p>Quoted</p></blockquote>`,
			want: `<p>Reply</p>`,
		},
		{
			name: "case insensitive",
			html: `<p>Reply</p><DIV CLASS="Gmail_Quote"><p>Quoted</p></DIV>`,
			want: `<p>Reply</p>`,
		},
		{
			name: "trailing whitespace stripped",
			html: "<p>Reply</p>  \n  <blockquote><p>Quoted</p></blockquote>",
			want: "<p>Reply</p>",
		},
		{
			name: "multiple quote patterns - earliest wins",
			html: `<p>Reply</p><blockquote type="cite"><p>Apple</p></blockquote><div class="gmail_quote"><p>Gmail</p></div>`,
			want: `<p>Reply</p>`,
		},
		{
			name: "Outlook Desktop border-top quote separator",
			html: `<p>Reply text</p><div><div style="border: none; border-top: solid #E1E1E1 1.0pt; padding: 3.0pt 0cm 0cm 0cm"><p><b>Von:</b> Someone</p></div></div>`,
			want: `<p>Reply text</p><div>`,
		},
		{
			name: "Outlook Desktop border-top different color",
			html: `<p>Reply</p><div><div style="border: none; border-top: solid #B5C4DF 1.0pt; padding: 3.0pt 0cm 0cm 0cm"><p><b>From:</b> Someone</p></div></div>`,
			want: `<p>Reply</p><div>`,
		},
		{
			name: "Outlook Desktop border-style solid none none",
			html: `<p>Reply</p><div style="padding: 3pt 0cm 0cm; border-width: 1pt medium medium; border-style: solid none none; border-color: rgb(225, 225, 225) currentcolor currentcolor"><p><b>Von:</b> Someone</p></div>`,
			want: `<p>Reply</p>`,
		},
		{
			name: "Outlook Mobile reference message class",
			html: `<p>Reply</p><div class="ms-outlook-mobile-reference-message skipProofing" style="padding: 3pt 0in 0in; border-style: solid none none; border-color: rgb(181, 196, 223) currentcolor"><b>From: </b>Someone</div>`,
			want: `<p>Reply</p>`,
		},
		{
			name: "Outlook hr separator with Von",
			html: `<p>Reply</p><hr style="display: inline-block; width: 98%"><div dir="ltr"><font face="Calibri" color="#000000"><b>Von:</b> Someone</font></div>`,
			want: `<p>Reply</p>`,
		},
		{
			name: "Ursprüngliche Nachricht separator",
			html: `<p>Reply</p><div>--------------- Ursprüngliche Nachricht ---------------<br><b>Von:</b> Someone</div>`,
			want: `<p>Reply</p><div>`,
		},
		{
			name: "Original Message separator",
			html: `<p>Reply</p><div>-------- Original Message --------</div><div>From: Someone</div>`,
			want: `<p>Reply</p><div>`,
		},
		{
			name: "forward with no added text preserves content",
			html: `<div><br></div><div class="ms-outlook-mobile-reference-message"><p>Forwarded content here</p></div>`,
			want: `<div><br></div><div class="ms-outlook-mobile-reference-message"><p>Forwarded content here</p></div>`,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := StripQuotedContent(tt.html)
			if got != tt.want {
				t.Errorf("StripQuotedContent() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestFlattenThread(t *testing.T) {
	tests := []struct {
		name     string
		input    string // JSON
		wantIDs  []string
	}{
		{
			name:    "single message",
			input:   `[[{"id": "msg1@test", "timestamp": 1000, "headers": {}, "body": [], "tags": ["inbox"], "filename": ["f1"]}]]`,
			wantIDs: []string{"msg1@test"},
		},
		{
			name: "two messages in thread",
			input: `[[
				{"id": "msg1@test", "timestamp": 1000, "headers": {}, "body": [], "tags": [], "filename": []},
				[
					{"id": "msg2@test", "timestamp": 2000, "headers": {}, "body": [], "tags": [], "filename": []},
					[]
				]
			]]`,
			wantIDs: []string{"msg1@test", "msg2@test"},
		},
		{
			name: "deeply nested replies",
			input: `[[
				{"id": "msg1@test", "timestamp": 1000, "headers": {}, "body": [], "tags": [], "filename": []},
				[
					{"id": "msg2@test", "timestamp": 2000, "headers": {}, "body": [], "tags": [], "filename": []},
					[
						{"id": "msg3@test", "timestamp": 3000, "headers": {}, "body": [], "tags": [], "filename": []},
						[]
					]
				]
			]]`,
			wantIDs: []string{"msg1@test", "msg2@test", "msg3@test"},
		},
		{
			name:    "empty thread",
			input:   `[]`,
			wantIDs: nil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var raw json.RawMessage
			if err := json.Unmarshal([]byte(tt.input), &raw); err != nil {
				t.Fatalf("invalid test JSON: %v", err)
			}

			var messages []ThreadMessage
			flattenThread(raw, &messages)

			if len(messages) != len(tt.wantIDs) {
				t.Errorf("got %d messages, want %d", len(messages), len(tt.wantIDs))
				return
			}

			for i, msg := range messages {
				if msg.ID != tt.wantIDs[i] {
					t.Errorf("message[%d].ID = %q, want %q", i, msg.ID, tt.wantIDs[i])
				}
			}
		})
	}
}

func TestExtractBodyContentStripsQuotedHTML(t *testing.T) {
	// Verify that ExtractBodyContent calls StripQuotedContent on HTML
	body := `[{"id": 1, "content-type": "text/html", "content": "<p>Reply</p><div class=\"gmail_quote\"><p>Original</p></div>"}]`

	var rawBody []json.RawMessage
	if err := json.Unmarshal([]byte(body), &rawBody); err != nil {
		t.Fatal(err)
	}

	_, html, _ := ExtractBodyContent(rawBody)

	if html != "<p>Reply</p>" {
		t.Errorf("expected quoted content to be stripped, got %q", html)
	}
}
