package draft

import "testing"

func TestExtractMessageID(t *testing.T) {
	tests := []struct {
		name string
		data string
		want string
	}{
		{
			"standard header",
			"From: test@example.com\r\nMessage-ID: <abc123@mail.example.com>\r\nSubject: Test\r\n",
			"abc123@mail.example.com",
		},
		{
			"lowercase header",
			"From: test@example.com\r\nMessage-Id: <def456@example.com>\r\nSubject: Test\r\n",
			"def456@example.com",
		},
		{
			"unix line endings",
			"From: test@example.com\nMessage-ID: <unix@example.com>\nSubject: Test\n",
			"unix@example.com",
		},
		{
			"no brackets",
			"Message-ID: plain-id@example.com\r\n",
			"plain-id@example.com",
		},
		{
			"with whitespace",
			"Message-ID:   <spaced@example.com>  \r\n",
			"spaced@example.com",
		},
		{
			"no message id header",
			"From: test@example.com\r\nSubject: No ID\r\n",
			"",
		},
		{
			"empty input",
			"",
			"",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := extractMessageID([]byte(tt.data))
			if got != tt.want {
				t.Errorf("extractMessageID() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestTrimSpace(t *testing.T) {
	tests := []struct {
		input, want string
	}{
		{"  hello  ", "hello"},
		{"\thello\t", "hello"},
		{"hello", "hello"},
		{"  ", ""},
		{"", ""},
	}
	for _, tt := range tests {
		if got := trimSpace(tt.input); got != tt.want {
			t.Errorf("trimSpace(%q) = %q, want %q", tt.input, got, tt.want)
		}
	}
}

func TestTrimBrackets(t *testing.T) {
	tests := []struct {
		input, want string
	}{
		{"<abc@example.com>", "abc@example.com"},
		{"no-brackets@example.com", "no-brackets@example.com"},
		{"<>", ""},
		{"a", "a"},
		{"", ""},
	}
	for _, tt := range tests {
		if got := trimBrackets(tt.input); got != tt.want {
			t.Errorf("trimBrackets(%q) = %q, want %q", tt.input, got, tt.want)
		}
	}
}

func TestIndexOf(t *testing.T) {
	tests := []struct {
		s, substr string
		want      int
	}{
		{"hello world", "world", 6},
		{"hello", "hello", 0},
		{"hello", "xyz", -1},
		{"", "a", -1},
		{"abc", "", 0},
	}
	for _, tt := range tests {
		if got := indexOf(tt.s, tt.substr); got != tt.want {
			t.Errorf("indexOf(%q, %q) = %d, want %d", tt.s, tt.substr, got, tt.want)
		}
	}
}
