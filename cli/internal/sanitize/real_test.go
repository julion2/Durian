package sanitize

import (
	"os"
	"path/filepath"
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

// TestRealEmailFixtures runs all HTML files in testdata/ through the sanitizer
// and asserts structural preservation. Each fixture is a real-world email HTML.
func TestRealEmailFixtures(t *testing.T) {
	files, err := filepath.Glob("testdata/*.html")
	if err != nil {
		t.Fatalf("Failed to glob testdata: %v", err)
	}
	if len(files) == 0 {
		t.Fatal("No HTML fixtures found in testdata/")
	}

	for _, file := range files {
		name := strings.TrimSuffix(filepath.Base(file), ".html")
		t.Run(name, func(t *testing.T) {
			raw, err := os.ReadFile(file)
			if err != nil {
				t.Fatalf("Failed to read %s: %v", file, err)
			}
			html := string(raw)
			result := SanitizeHTML(html)

			ratio := float64(len(result)) / float64(len(html)) * 100
			t.Logf("%d → %d chars (%.1f%%)", len(html), len(result), ratio)

			// Every real email should preserve at least 50% of its content
			if len(result) < len(html)/2 {
				t.Errorf("Too much content stripped: %d → %d chars (%.0f%%)", len(html), len(result), ratio)
			}

			// Script execution vectors must never survive
			lower := strings.ToLower(result)
			for _, bad := range []string{"<script", "<iframe", "<object", "<embed"} {
				if strings.Contains(lower, bad) {
					t.Errorf("Dangerous element %s found in output", bad)
				}
			}
		})
	}
}
