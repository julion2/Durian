package sanitize

import (
	"os"
	"strings"
	"testing"
)

// TestVoidElementsDoNotEatContent verifies that void elements (meta, link, base)
// are stripped without swallowing subsequent HTML content.
// Regression test: SkipElementsContent on void elements caused bluemonday to eat
// everything after the first <meta> because void elements never produce a closing
// tag token from Go's html.Tokenizer.
func TestVoidElementsDoNotEatContent(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  string
	}{
		{
			"meta then content",
			`<meta charset="UTF-8"><p>visible</p>`,
			"visible",
		},
		{
			"link then content",
			`<link rel="stylesheet" href="x"><p>visible</p>`,
			"visible",
		},
		{
			"base then content",
			`<base href="x"><p>visible</p>`,
			"visible",
		},
		{
			"full email structure",
			`<html><head><meta charset="UTF-8"><link href="x"></head><body><table><tr><td>data</td></tr></table><a href="https://example.com">Click</a></body></html>`,
			"data",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := SanitizeHTML(tt.input)
			if !strings.Contains(result, tt.want) {
				t.Errorf("Expected %q in output, got: %s", tt.want, result)
			}
		})
	}
}

func TestRealDoodleNewsletter(t *testing.T) {
	raw, err := os.ReadFile("testdata/doodle_newsletter.html")
	if err != nil {
		t.Fatalf("Failed to read test fixture: %v", err)
	}
	html := string(raw)

	result := SanitizeHTML(html)
	t.Logf("Input: %d chars → Output: %d chars (%.1f%%)", len(html), len(result),
		float64(len(result))/float64(len(html))*100)

	if !strings.Contains(result, "<table") {
		t.Error("Expected <table> in output")
	}
	if !strings.Contains(result, "<a href") {
		t.Error("Expected <a href> in output")
	}
	if !strings.Contains(result, "<style>") {
		t.Error("Expected <style> in output")
	}
	if len(result) < len(html)/2 {
		t.Errorf("Sanitized HTML too short (%d chars, %.0f%% of input), expected >50%% preservation",
			len(result), float64(len(result))/float64(len(html))*100)
	}
}
