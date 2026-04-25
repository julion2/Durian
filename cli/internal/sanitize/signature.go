package sanitize

import "strings"

// signatureMarkers are HTML patterns that indicate the start of an email
// signature. Kept intentionally conservative — unrecognized signatures are
// shown rather than incorrectly stripped.
var signatureMarkers = []string{
	// RFC 3676 separator wrapped in block elements
	"<div>-- <br></div>",
	"<div>-- <br/></div>",
	"<div>-- <br /></div>",

	// Thunderbird
	`<div class="moz-signature"`,

	// Gmail
	`<div class="gmail_signature"`,

	// Apple Mail
	`<div id="applemailsignature"`,
}

// DetectSignature returns the byte index where the signature begins in
// the given HTML, or -1 if no known signature marker is found.
func DetectSignature(html string) int {
	if html == "" {
		return -1
	}
	lower := strings.ToLower(html)
	for _, marker := range signatureMarkers {
		if idx := strings.Index(lower, marker); idx != -1 {
			return idx
		}
	}
	return -1
}

// StripSignature removes the signature from HTML content.
// Returns the original HTML if no signature is detected.
func StripSignature(html string) string {
	idx := DetectSignature(html)
	if idx == -1 {
		return html
	}
	return strings.TrimRight(html[:idx], " \t\n\r")
}

// ExtractSignature returns the signature portion of HTML content,
// or an empty string if no signature marker is found.
func ExtractSignature(html string) string {
	idx := DetectSignature(html)
	if idx == -1 {
		return ""
	}
	return html[idx:]
}

// CommonSuffix returns the longest common suffix of two strings.
// Used to detect signatures by comparing multiple messages from the
// same sender — the identical trailing content is the signature.
func CommonSuffix(a, b string) string {
	i, j := len(a)-1, len(b)-1
	for i >= 0 && j >= 0 && a[i] == b[j] {
		i--
		j--
	}
	return a[i+1:]
}
