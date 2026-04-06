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

	// NOTE: Generic <blockquote> is intentionally NOT in this list.
	// It would strip legitimate user quotes (citations, code, etc.).
}

// mobileSignatures are auto-generated client signatures that should be treated
// as "no real user content" — when only these appear above a quote, the original
// (with the forward/reply intact) is kept.
var mobileSignatures = []string{
	"sent from outlook for ios",
	"sent from outlook for android",
	"sent from my iphone",
	"sent from my ipad",
	"sent from my android",
	"sent from mail for windows",
	"get outlook for ios",
	"get outlook for android",
	"von meinem iphone gesendet",
	"von meinem ipad gesendet",
	"gesendet von outlook für ios",
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

	// Durian: <div style="color: #555;"><p ...>On ..., ... wrote:</p>
	regexp.MustCompile(`(?i)<div[^>]*style="color:\s*#555;?"[^>]*>\s*<p[^>]*>On\s`),
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

	// If stripping leaves only empty HTML or just a mobile signature
	// (e.g. "Sent from Outlook for iOS"), keep the original so the
	// forwarded content remains visible.
	if isEffectivelyEmpty(stripped) {
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

// isEffectivelyEmpty returns true if the HTML contains no meaningful user
// content — either truly empty or only an auto-generated mobile signature.
func isEffectivelyEmpty(html string) bool {
	// Strip all tags and entities to get plain text
	text := htmlTagOrSpace.ReplaceAllString(html, " ")
	text = strings.TrimSpace(text)
	if text == "" {
		return true
	}

	textLower := strings.ToLower(text)
	for _, sig := range mobileSignatures {
		// Check if the text is JUST the signature (with optional surrounding noise)
		if strings.Contains(textLower, sig) {
			// Remove the signature and check if anything substantive remains
			remainder := strings.ReplaceAll(textLower, sig, "")
			remainder = strings.TrimSpace(remainder)
			if len(remainder) < 5 {
				return true
			}
		}
	}
	return false
}
