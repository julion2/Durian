package sanitize

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"regexp"
	"strings"
	"sync"

	"github.com/microcosm-cc/bluemonday"
)

var (
	policy     *bluemonday.Policy
	policyOnce sync.Once
)

// dangerousCSSValue detects CSS values that can execute code.
// Only expression() and javascript: are real execution vectors.
// url(), @import, -moz-binding are all dead under CSP default-src 'none'.
var dangerousCSSValue = regexp.MustCompile(
	`(?i)(expression|javascript)`,
)

// allowedCSSProperties covers all common CSS properties found in HTML emails.
// Broad allowlist is safe because the WebView CSP (default-src 'none'; style-src 'unsafe-inline')
// blocks all resource loading from CSS — url(), @import etc. are inert.
var allowedCSSProperties = []string{
	// Text
	"color", "font", "font-family", "font-size", "font-style", "font-weight", "font-variant",
	"text-align", "text-decoration", "text-indent", "text-transform", "text-overflow",
	"letter-spacing", "word-spacing", "word-wrap", "word-break",
	"line-height", "white-space", "direction", "unicode-bidi",
	// Box model
	"margin", "margin-top", "margin-right", "margin-bottom", "margin-left",
	"padding", "padding-top", "padding-right", "padding-bottom", "padding-left",
	"border", "border-top", "border-right", "border-bottom", "border-left",
	"border-color", "border-style", "border-width",
	"border-top-color", "border-right-color", "border-bottom-color", "border-left-color",
	"border-top-style", "border-right-style", "border-bottom-style", "border-left-style",
	"border-top-width", "border-right-width", "border-bottom-width", "border-left-width",
	"border-collapse", "border-spacing", "border-radius",
	// Layout
	"display", "width", "height", "min-width", "min-height", "max-width", "max-height",
	"overflow", "overflow-x", "overflow-y",
	"float", "clear", "vertical-align", "table-layout", "box-sizing",
	// Background
	"background", "background-color", "background-image", "background-repeat",
	"background-position", "background-size",
	// Position
	"position", "top", "right", "bottom", "left", "z-index",
	// Visibility
	"visibility", "opacity",
	// List
	"list-style", "list-style-type", "list-style-position",
	// Table
	"empty-cells", "caption-side",
	// Misc
	"cursor", "outline", "box-shadow", "text-shadow",
	// Flexbox
	"flex", "flex-direction", "flex-wrap", "justify-content", "align-items", "align-self",
	"order", "flex-grow", "flex-shrink", "flex-basis",
	// Grid
	"grid", "grid-template-columns", "grid-template-rows", "grid-gap", "gap",
	// Transform
	"transition", "transform",
}

// colorOrURL matches color values, URLs, and general CSS values.
var colorOrURL = regexp.MustCompile(`(?i)^.+$`)

func buildPolicy() *bluemonday.Policy {
	p := bluemonday.NewPolicy()

	// --- Document structure ---
	p.AllowElements("html", "head", "body")

	// --- Structural / text elements ---
	p.AllowElements(
		"p", "br", "div", "span",
		"h1", "h2", "h3", "h4", "h5", "h6",
		"b", "i", "u", "strong", "em", "s", "del", "ins", "mark",
		"small", "big", "wbr",
		"ul", "ol", "li",
		"blockquote", "pre", "code",
		"hr", "sub", "sup",
		"abbr", "address", "cite",
		"dl", "dt", "dd",
		"figure", "figcaption",
		"header", "footer", "main", "nav",
		"section", "article", "aside",
		"details", "summary",
	)

	// Allow HTML comments (needed for Outlook conditional comments in email HTML)
	p.AllowComments()

	// --- Legacy presentational elements (common in email HTML) ---
	p.AllowElements("font", "center", "caption")

	// --- Tables ---
	p.AllowElements("table", "thead", "tbody", "tfoot", "tr", "td", "th", "col", "colgroup")
	p.AllowAttrs("colspan", "rowspan").Matching(bluemonday.Integer).OnElements("td", "th")
	p.AllowAttrs("cellpadding", "cellspacing", "border").Matching(bluemonday.Integer).OnElements("table")
	p.AllowAttrs("rules").Matching(regexp.MustCompile(`(?i)^(none|groups|rows|cols|all)$`)).OnElements("table")
	p.AllowAttrs("frame").Matching(regexp.MustCompile(`(?i)^(void|above|below|hsides|lhs|rhs|vsides|box|border)$`)).OnElements("table")
	p.AllowAttrs("summary").Matching(colorOrURL).OnElements("table")
	p.AllowAttrs("width", "height").Matching(bluemonday.NumberOrPercent).OnElements("table", "td", "th", "col", "colgroup", "img")
	p.AllowAttrs("valign").Matching(regexp.MustCompile(`(?i)^(top|middle|bottom|baseline)$`)).OnElements("td", "th", "tr")
	p.AllowAttrs("nowrap").Matching(regexp.MustCompile(`(?i)^(|nowrap)$`)).OnElements("td", "th")
	p.AllowAttrs("scope").Matching(regexp.MustCompile(`(?i)^(row|col|rowgroup|colgroup)$`)).OnElements("td", "th")
	p.AllowAttrs("background").Matching(colorOrURL).OnElements("table", "td", "th", "tr")
	p.AllowAttrs("span").Matching(bluemonday.Integer).OnElements("col", "colgroup")

	// --- Font attributes ---
	p.AllowAttrs("color", "face").Matching(colorOrURL).OnElements("font")
	p.AllowAttrs("size").Matching(regexp.MustCompile(`^[+-]?[0-9]+$`)).OnElements("font")

	// --- Links ---
	p.AllowElements("a")
	p.AllowAttrs("href").OnElements("a")
	p.AllowAttrs("name").Matching(colorOrURL).OnElements("a")
	p.RequireParseableURLs(true)
	p.AllowURLSchemes("http", "https", "mailto", "cid")
	p.RequireNoFollowOnFullyQualifiedLinks(true)
	p.AddTargetBlankToFullyQualifiedLinks(true)

	// --- Images ---
	p.AllowElements("img")
	p.AllowAttrs("src").OnElements("img")
	p.AllowDataURIImages()
	p.AllowAttrs("alt").OnElements("img")
	p.AllowAttrs("border", "hspace", "vspace").Matching(bluemonday.Integer).OnElements("img")

	// --- Global safe attributes ---
	p.AllowAttrs("class", "dir", "lang", "title", "role").Globally()
	p.AllowAttrs("xml:lang", "xmlns").Matching(colorOrURL).OnElements("html")
	p.AllowAttrs("align").Matching(regexp.MustCompile(`(?i)^(left|center|right|justify)$`)).Globally()
	p.AllowAttrs("bgcolor").Matching(regexp.MustCompile(`(?i)^(#[0-9a-f]{3,8}|[a-z]+)$`)).Globally()
	p.AllowAttrs("background").Matching(colorOrURL).Globally()

	// --- CSS property allowlist ---
	// Broad allowlist is safe: CSP blocks all resource loading from CSS.
	// Only expression() and javascript: are stripped as defense-in-depth.
	safeCSSValue := func(value string) bool {
		return !dangerousCSSValue.MatchString(value)
	}
	for _, prop := range allowedCSSProperties {
		p.AllowStyles(prop).MatchingHandler(safeCSSValue).Globally()
	}

	// --- Remove script execution vectors (tag + content) ---
	// Everything else is allowed through. CSP default-src 'none' in the
	// WebView kills all external resource loading and script execution.
	// NOTE: Only use SkipElementsContent for non-void elements.
	// Void elements (meta, link, base) must NOT be listed here — they never
	// produce a closing tag, so bluemonday would eat all subsequent content.
	// They're already stripped by bluemonday (not in the allowlist).
	p.SkipElementsContent(
		"script",
		"iframe", "object", "embed",
	)

	return p
}

func getPolicy() *bluemonday.Policy {
	policyOnce.Do(func() {
		policy = buildPolicy()
	})
	return policy
}

// svgDataURI matches data:image/svg+xml URIs that bluemonday lets through.
var svgDataURI = regexp.MustCompile(`(?i)\s+src="data:image/svg\+xml[^"]*"`)

// styleTagRe matches <style>...</style> blocks including attributes.
var styleTagRe = regexp.MustCompile(`(?is)<style[^>]*>(.*?)</style>`)

// cleanStyleContent sanitizes CSS content inside a <style> block.
// Strips @import lines as defense-in-depth (blocked by CSP anyway).
func cleanStyleContent(css string) string {
	var out []string
	for _, line := range strings.Split(css, "\n") {
		if !strings.Contains(strings.ToLower(line), "@import") {
			out = append(out, line)
		}
	}
	return strings.Join(out, "\n")
}

// preserveStyleTags extracts <style> blocks, replaces them with UUID
// placeholders, and returns the modified HTML plus a map to re-inject later.
func preserveStyleTags(html string) (string, map[string]string) {
	placeholders := make(map[string]string)
	result := styleTagRe.ReplaceAllStringFunc(html, func(match string) string {
		subs := styleTagRe.FindStringSubmatch(match)
		if len(subs) < 2 {
			return ""
		}
		cleaned := cleanStyleContent(subs[1])
		if strings.TrimSpace(cleaned) == "" {
			return ""
		}
		b := make([]byte, 16)
		rand.Read(b)
		id := hex.EncodeToString(b)
		placeholder := fmt.Sprintf("DURIANSTYLEPLACEHOLDER%s", id)
		placeholders[placeholder] = fmt.Sprintf("<style>%s</style>", cleaned)
		return placeholder
	})
	return result, placeholders
}

// reinjectStyleTags replaces UUID placeholders with cleaned <style> blocks.
func reinjectStyleTags(html string, placeholders map[string]string) string {
	for placeholder, style := range placeholders {
		html = strings.Replace(html, placeholder, style, 1)
	}
	return html
}

// SanitizeHTML sanitizes untrusted HTML email content using a whitelist policy.
// Safe for use in rendering contexts where JavaScript may be enabled.
func SanitizeHTML(html string) string {
	if html == "" {
		return ""
	}
	// Pre-extract <style> blocks before bluemonday (which would escape CSS selectors).
	stripped, placeholders := preserveStyleTags(html)
	result := getPolicy().Sanitize(stripped)
	// Post-process: strip SVG data URI src attrs (can contain embedded scripts).
	if strings.Contains(result, "data:image/svg") {
		result = svgDataURI.ReplaceAllString(result, "")
	}
	// Re-inject cleaned <style> blocks at their placeholder positions.
	if len(placeholders) > 0 {
		result = reinjectStyleTags(result, placeholders)
	}
	return result
}
