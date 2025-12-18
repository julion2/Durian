package encoding

import (
	"os/exec"
	"strings"
)

// HTMLToText converts HTML content to plain text
// Uses w3m if available, falls back to simple tag stripping
func HTMLToText(html string) string {
	cmd := exec.Command("w3m", "-T", "text/html", "-I", "UTF-8", "-O", "UTF-8", "-dump")
	cmd.Stdin = strings.NewReader(html)
	out, err := cmd.Output()
	if err != nil {
		return stripHTMLTags(html)
	}
	return string(out)
}

// stripHTMLTags is a simple fallback for removing HTML tags
func stripHTMLTags(html string) string {
	result := html
	for strings.Contains(result, "<") {
		start := strings.Index(result, "<")
		end := strings.Index(result, ">")
		if end > start {
			result = result[:start] + result[end+1:]
		} else {
			break
		}
	}
	return result
}
