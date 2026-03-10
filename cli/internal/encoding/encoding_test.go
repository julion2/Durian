package encoding

import (
	"testing"
)

func TestConvertToUTF8(t *testing.T) {
	tests := []struct {
		name     string
		data     []byte
		charset  string
		expected string
	}{
		{
			name:     "UTF-8 passthrough",
			data:     []byte("Hello World"),
			charset:  "utf-8",
			expected: "Hello World",
		},
		{
			name:     "UTF-8 with umlauts",
			data:     []byte("Grüße"),
			charset:  "utf-8",
			expected: "Grüße",
		},
		{
			name:     "Empty charset with valid UTF-8",
			data:     []byte("Hello"),
			charset:  "",
			expected: "Hello",
		},
		{
			name:     "US-ASCII",
			data:     []byte("Hello"),
			charset:  "us-ascii",
			expected: "Hello",
		},
		{
			name:     "ISO-8859-1 umlauts",
			data:     []byte{0xe4, 0xf6, 0xfc}, // äöü in ISO-8859-1
			charset:  "iso-8859-1",
			expected: "äöü",
		},
		{
			name:     "ISO-8859-1 latin1 alias",
			data:     []byte{0xe4, 0xf6, 0xfc},
			charset:  "latin1",
			expected: "äöü",
		},
		{
			name:     "ISO-8859-15 with Euro sign",
			data:     []byte{0xa4}, // € in ISO-8859-15
			charset:  "iso-8859-15",
			expected: "€",
		},
		{
			name:     "Windows-1252 smart quotes",
			data:     []byte{0x93, 0x94}, // "" in Windows-1252
			charset:  "windows-1252",
			expected: "\u201c\u201d",
		},
		{
			name:     "Windows-1252 cp1252 alias",
			data:     []byte{0x93, 0x94},
			charset:  "cp1252",
			expected: "\u201c\u201d",
		},
		{
			name:     "Empty data",
			data:     []byte{},
			charset:  "utf-8",
			expected: "",
		},
		{
			name:     "Charset with spaces",
			data:     []byte("Hello"),
			charset:  "  utf-8  ",
			expected: "Hello",
		},
		{
			name:     "Uppercase charset",
			data:     []byte{0xe4, 0xf6, 0xfc},
			charset:  "ISO-8859-1",
			expected: "äöü",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := ConvertToUTF8(tt.data, tt.charset)
			if result != tt.expected {
				t.Errorf("ConvertToUTF8() = %q, want %q", result, tt.expected)
			}
		})
	}
}

func TestGetCharset(t *testing.T) {
	tests := []struct {
		name        string
		contentType string
		expected    string
	}{
		{
			name:        "UTF-8 charset",
			contentType: "text/plain; charset=utf-8",
			expected:    "utf-8",
		},
		{
			name:        "ISO-8859-1 charset",
			contentType: "text/html; charset=ISO-8859-1",
			expected:    "ISO-8859-1",
		},
		{
			name:        "No charset",
			contentType: "text/plain",
			expected:    "",
		},
		{
			name:        "Multipart with boundary only",
			contentType: "multipart/mixed; boundary=----=_Part_123",
			expected:    "",
		},
		{
			name:        "Empty content type",
			contentType: "",
			expected:    "",
		},
		{
			name:        "Charset with quotes",
			contentType: `text/plain; charset="utf-8"`,
			expected:    "utf-8",
		},
		{
			name:        "Multiple params",
			contentType: "text/plain; charset=utf-8; format=flowed",
			expected:    "utf-8",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := GetCharset(tt.contentType)
			if result != tt.expected {
				t.Errorf("GetCharset() = %q, want %q", result, tt.expected)
			}
		})
	}
}

func TestDecodeBody(t *testing.T) {
	tests := []struct {
		name             string
		body             []byte
		transferEncoding string
		charset          string
		expected         string
	}{
		{
			name:             "Plain text no encoding",
			body:             []byte("Hello World"),
			transferEncoding: "",
			charset:          "",
			expected:         "Hello World",
		},
		{
			name:             "Base64 encoded",
			body:             []byte("SGVsbG8gV29ybGQ="),
			transferEncoding: "base64",
			charset:          "",
			expected:         "Hello World",
		},
		{
			name:             "Base64 with newlines",
			body:             []byte("SGVsbG8g\nV29ybGQ="),
			transferEncoding: "base64",
			charset:          "",
			expected:         "Hello World",
		},
		{
			name:             "Quoted-printable simple",
			body:             []byte("Hello=20World"),
			transferEncoding: "quoted-printable",
			charset:          "",
			expected:         "Hello World",
		},
		{
			name:             "Quoted-printable with umlauts UTF-8",
			body:             []byte("Gr=C3=BC=C3=9Fe"),
			transferEncoding: "quoted-printable",
			charset:          "utf-8",
			expected:         "Grüße",
		},
		{
			name:             "7bit encoding (passthrough)",
			body:             []byte("Hello World"),
			transferEncoding: "7bit",
			charset:          "",
			expected:         "Hello World",
		},
		{
			name:             "8bit encoding (passthrough)",
			body:             []byte("Hello World"),
			transferEncoding: "8bit",
			charset:          "",
			expected:         "Hello World",
		},
		{
			name:             "Base64 uppercase",
			body:             []byte("SGVsbG8gV29ybGQ="),
			transferEncoding: "BASE64",
			charset:          "",
			expected:         "Hello World",
		},
		{
			name:             "Base64 with charset conversion",
			body:             []byte("5Pb8"), // äöü in ISO-8859-1, base64 encoded
			transferEncoding: "base64",
			charset:          "iso-8859-1",
			expected:         "äöü",
		},
		{
			name:             "Invalid base64 fallback",
			body:             []byte("not valid base64!!!"),
			transferEncoding: "base64",
			charset:          "",
			expected:         "not valid base64!!!",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := DecodeBody(tt.body, tt.transferEncoding, tt.charset)
			if result != tt.expected {
				t.Errorf("DecodeBody() = %q, want %q", result, tt.expected)
			}
		})
	}
}

func TestDecodeHeader(t *testing.T) {
	tests := []struct {
		name     string
		header   string
		expected string
	}{
		{
			name:     "Plain ASCII header",
			header:   "Hello World",
			expected: "Hello World",
		},
		{
			name:     "RFC 2047 Q-encoding UTF-8",
			header:   "=?UTF-8?Q?Gr=C3=BC=C3=9Fe?=",
			expected: "Grüße",
		},
		{
			name:     "RFC 2047 B-encoding UTF-8",
			header:   "=?UTF-8?B?R3LDvMOfZQ==?=",
			expected: "Grüße",
		},
		{
			name:     "RFC 2047 ISO-8859-1",
			header:   "=?ISO-8859-1?Q?Gr=FC=DFe?=",
			expected: "Grüße",
		},
		{
			name:     "Mixed encoded and plain",
			header:   "Re: =?UTF-8?Q?Gr=C3=BC=C3=9Fe?= from Berlin",
			expected: "Re: Grüße from Berlin",
		},
		{
			name:     "Empty header",
			header:   "",
			expected: "",
		},
		{
			name:     "Email address with encoded name",
			header:   "=?UTF-8?Q?M=C3=BCller?= <mueller@example.com>",
			expected: "Müller <mueller@example.com>",
		},
		{
			name:     "Windows-1252 Q-encoding",
			header:   "=?Windows-1252?Q?Mustermann=2C_R=FCdiger?= <max@example.com>",
			expected: "Mustermann, Rüdiger <max@example.com>",
		},
		{
			name:     "Multi-word ISO-8859-1 filename",
			header:   "=?iso-8859-1?Q?Offene_Rechnungen_-_Zahlungseing=E4nge_ber=FCc?= =?iso-8859-1?Q?ksichtigt.PDF?=",
			expected: "Offene Rechnungen - Zahlungseingänge berücksichtigt.PDF",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := DecodeHeader(tt.header)
			if result != tt.expected {
				t.Errorf("DecodeHeader() = %q, want %q", result, tt.expected)
			}
		})
	}
}

func TestStripHTMLTags(t *testing.T) {
	tests := []struct {
		name     string
		html     string
		expected string
	}{
		{
			name:     "Simple paragraph",
			html:     "<p>Hello World</p>",
			expected: "Hello World",
		},
		{
			name:     "Nested tags",
			html:     "<div><span>Hello</span> <b>World</b></div>",
			expected: "Hello World",
		},
		{
			name:     "No tags",
			html:     "Hello World",
			expected: "Hello World",
		},
		{
			name:     "Self-closing tags",
			html:     "Hello<br/>World",
			expected: "HelloWorld",
		},
		{
			name:     "Multiple paragraphs",
			html:     "<p>Hello</p><p>World</p>",
			expected: "HelloWorld",
		},
		{
			name:     "Empty string",
			html:     "",
			expected: "",
		},
		{
			name:     "Tags with attributes",
			html:     `<a href="http://example.com">Link</a>`,
			expected: "Link",
		},
		{
			name:     "Script and style should be removed",
			html:     "<div>Hello<script>alert('x')</script>World</div>",
			expected: "Helloalert('x')World",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := stripHTMLTags(tt.html)
			if result != tt.expected {
				t.Errorf("stripHTMLTags() = %q, want %q", result, tt.expected)
			}
		})
	}
}
