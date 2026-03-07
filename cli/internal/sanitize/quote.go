package sanitize

import (
	"regexp"
	"strings"
)

// quotePatterns defines HTML patterns that indicate quoted/forwarded content.
var quotePatterns = []string{
	// Outlook Web
	`<div id="mail-editor-reference-message-container"`,
	`<div id="appendonsend"`,
	`<div id="divRplyFwdMsg"`,
	`<div name="divRplyFwdMsg"`,

	// Outlook Mobile
	`<div class="ms-outlook-mobile-reference-message`,

	// Gmail
	`<div class="gmail_quote"`,
	`<div class="gmail_extra"`,
	`<blockquote class="gmail_quote"`,

	// Apple Mail
	`<blockquote type="cite"`,

	// Generic blockquote (fallback)
	`<blockquote`,
}

// quoteRegexPatterns defines regex patterns for quoted content that can't be matched
// with simple string patterns (e.g. inline styles with variable values).
var quoteRegexPatterns = []*regexp.Regexp{
	// Outlook Desktop: <div style="border: none; border-top: solid #E1E1E1 1.0pt; padding: ...">
	regexp.MustCompile(`(?i)<div[^>]*style="[^"]*border-top:\s*solid\s[^"]*padding:[^"]*">`),
	// Outlook Desktop variant: padding + border-style: solid none none (either order)
	regexp.MustCompile(`(?i)<div[^>]*style="[^"]*border-style:\s*solid\s+none\s+none[^"]*">`),
	// Outlook: <hr> followed by Von:/From: header block
	regexp.MustCompile(`(?i)<hr[^>]*>\s*<div[^>]*>(?:\s*<font[^>]*>)?\s*(?:<[^>]*>)*\s*<b>(?:Von|From):</b>`),
	// Forwarded message separators (German/English)
	regexp.MustCompile(`(?i)-{3,}\s*Urspr(?:ü|&uuml;|&#xFC;)ngliche Nachricht\s*-{3,}`),
	regexp.MustCompile(`(?i)-{3,}\s*Original Message\s*-{3,}`),
}

// StripQuotedContent removes quoted reply content from HTML.
func StripQuotedContent(html string) string {
	if html == "" {
		return html
	}

	htmlLower := strings.ToLower(html)

	earliestIdx := -1
	for _, pattern := range quotePatterns {
		idx := strings.Index(htmlLower, strings.ToLower(pattern))
		if idx != -1 && (earliestIdx == -1 || idx < earliestIdx) {
			earliestIdx = idx
		}
	}

	for _, re := range quoteRegexPatterns {
		loc := re.FindStringIndex(html)
		if loc != nil && (earliestIdx == -1 || loc[0] < earliestIdx) {
			earliestIdx = loc[0]
		}
	}

	if earliestIdx == -1 {
		return html
	}

	stripped := html[:earliestIdx]
	stripped = strings.TrimRight(stripped, " \t\n\r")

	// If stripping leaves only empty HTML (e.g. a pure forward with no added text),
	// keep the original so the forwarded content remains visible.
	if isEmptyHTML(stripped) {
		return html
	}

	return stripped
}

// htmlTagOrSpace matches HTML tags and whitespace.
var htmlTagOrSpace = regexp.MustCompile(`(?:<[^>]*>|\s|&nbsp;)+`)

// isEmptyHTML returns true if the HTML contains no visible text content.
func isEmptyHTML(html string) bool {
	return strings.TrimSpace(htmlTagOrSpace.ReplaceAllString(html, "")) == ""
}
