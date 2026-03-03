package sanitize

import (
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
var dangerousCSSValue = regexp.MustCompile(
	`(?i)(expression|url|javascript|import|binding)`,
)

// allowedCSSProperties defines the CSS properties allowed in style attributes.
var allowedCSSProperties = []string{
	"color", "background-color",
	"font-size", "font-weight", "font-style", "font-family",
	"text-align", "text-decoration",
	"margin", "margin-top", "margin-right", "margin-bottom", "margin-left",
	"padding", "padding-top", "padding-right", "padding-bottom", "padding-left",
	"border", "border-top", "border-right", "border-bottom", "border-left",
	"border-color", "border-style", "border-width",
	"vertical-align", "line-height", "white-space",
}

func buildPolicy() *bluemonday.Policy {
	p := bluemonday.NewPolicy()

	// --- Structural / text elements ---
	p.AllowElements(
		"p", "br", "div", "span",
		"h1", "h2", "h3", "h4", "h5", "h6",
		"b", "i", "u", "strong", "em",
		"ul", "ol", "li",
		"blockquote", "pre", "code",
		"hr", "sub", "sup",
	)

	// --- Tables ---
	p.AllowElements("table", "thead", "tbody", "tr", "td", "th")
	p.AllowAttrs("colspan", "rowspan").Matching(bluemonday.Integer).OnElements("td", "th")

	// --- Links ---
	p.AllowElements("a")
	p.AllowAttrs("href").OnElements("a")
	p.RequireParseableURLs(true)
	p.AllowURLSchemes("http", "https", "mailto", "cid")
	p.RequireNoFollowOnFullyQualifiedLinks(true)
	p.AddTargetBlankToFullyQualifiedLinks(true)

	// --- Images ---
	// AllowDataURIImages permits data:image/* with valid base64 payloads.
	// SVG data URIs are stripped in post-processing (can contain embedded scripts).
	p.AllowElements("img")
	p.AllowAttrs("src").OnElements("img")
	p.AllowDataURIImages()
	p.AllowAttrs("alt").OnElements("img")

	// --- Size attributes (img + table only) ---
	p.AllowAttrs("width", "height").Matching(bluemonday.NumberOrPercent).OnElements("img", "table")

	// --- Global safe attributes ---
	p.AllowAttrs("class").Globally()
	p.AllowAttrs("align").Matching(regexp.MustCompile(`(?i)^(left|center|right|justify)$`)).Globally()
	p.AllowAttrs("bgcolor").Matching(regexp.MustCompile(`(?i)^(#[0-9a-f]{3,8}|[a-z]+)$`)).Globally()

	// --- CSS property whitelist ---
	safeCSSValue := func(value string) bool {
		return !dangerousCSSValue.MatchString(value)
	}
	for _, prop := range allowedCSSProperties {
		p.AllowStyles(prop).MatchingHandler(safeCSSValue).Globally()
	}

	// --- Remove dangerous elements entirely (tag + content) ---
	p.SkipElementsContent(
		"script", "style", "link",
		"form", "input", "textarea", "select", "button",
		"iframe", "object", "embed",
		"svg", "math",
		"base", "meta",
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

// SanitizeHTML sanitizes untrusted HTML email content using a whitelist policy.
// Safe for use in rendering contexts where JavaScript may be enabled.
func SanitizeHTML(html string) string {
	if html == "" {
		return ""
	}
	result := getPolicy().Sanitize(html)
	// Post-process: strip SVG data URI src attrs (can contain embedded scripts).
	if strings.Contains(result, "data:image/svg") {
		result = svgDataURI.ReplaceAllString(result, "")
	}
	return result
}
