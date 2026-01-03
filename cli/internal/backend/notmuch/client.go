package notmuch

import (
	"encoding/json"
	"os/exec"
	"strconv"
	"strings"
)

// SearchResult represents a single result from notmuch search
type SearchResult struct {
	Thread       string   `json:"thread"`
	Timestamp    int64    `json:"timestamp"`
	Subject      string   `json:"subject"`
	Authors      string   `json:"authors"`
	DateRelative string   `json:"date_relative"`
	Tags         []string `json:"tags"`
}

// ThreadMessage represents a single message from notmuch show
type ThreadMessage struct {
	ID        string            `json:"id"`
	Timestamp int64             `json:"timestamp"`
	Headers   map[string]string `json:"headers"`
	Body      []json.RawMessage `json:"body"`
	Tags      []string          `json:"tags"`
	Filename  []string          `json:"filename"`
}

// BodyPart represents a part of the message body (for parsing)
type BodyPart struct {
	ID                 int             `json:"id"`
	ContentType        string          `json:"content-type"`
	Content            json.RawMessage `json:"content,omitempty"` // Can be string or array
	ContentDisposition string          `json:"content-disposition,omitempty"`
	Filename           string          `json:"filename,omitempty"`
}

// ExtractBodyContent extracts text/plain, text/html and attachments from a message
// HTML content is stripped of quoted reply content to avoid duplicates in thread view
func ExtractBodyContent(body []json.RawMessage) (text, html string, attachments []string) {
	for _, raw := range body {
		extractFromRaw(raw, &text, &html, &attachments)
	}
	// Strip quoted content from HTML after extraction
	html = StripQuotedContent(html)
	return
}

// quotePatterns defines HTML patterns that indicate quoted/forwarded content
// Order matters: more specific patterns should come before generic ones
var quotePatterns = []string{
	// Outlook
	`<div id="mail-editor-reference-message-container"`,
	`<div id="appendonsend"`,
	`<div id="divRplyFwdMsg"`,
	`<div name="divRplyFwdMsg"`,

	// Gmail
	`<div class="gmail_quote"`,
	`<div class="gmail_extra"`,
	`<blockquote class="gmail_quote"`,

	// Apple Mail
	`<blockquote type="cite"`,

	// Generic blockquote (fallback - must be last)
	`<blockquote`,
}

// StripQuotedContent removes quoted reply content from HTML
// It finds the first quote marker and removes everything from there
func StripQuotedContent(html string) string {
	if html == "" {
		return html
	}

	htmlLower := strings.ToLower(html)

	// Find the earliest quote pattern
	earliestIdx := -1
	for _, pattern := range quotePatterns {
		idx := strings.Index(htmlLower, strings.ToLower(pattern))
		if idx != -1 && (earliestIdx == -1 || idx < earliestIdx) {
			earliestIdx = idx
		}
	}

	if earliestIdx == -1 {
		return html // No quote found
	}

	// Cut at the quote start
	stripped := html[:earliestIdx]

	// Clean up trailing whitespace
	stripped = strings.TrimRight(stripped, " \t\n\r")

	return stripped
}

func extractFromRaw(raw json.RawMessage, text, html *string, attachments *[]string) {
	var part BodyPart
	if err := json.Unmarshal(raw, &part); err != nil {
		return
	}

	// Check for attachment
	if part.ContentDisposition == "attachment" && part.Filename != "" {
		*attachments = append(*attachments, part.Filename)
		return
	}

	// Handle multipart: content is an array of parts
	if strings.HasPrefix(part.ContentType, "multipart/") {
		var subParts []json.RawMessage
		if err := json.Unmarshal(part.Content, &subParts); err == nil {
			for _, sub := range subParts {
				extractFromRaw(sub, text, html, attachments)
			}
		}
		return
	}

	// Extract text content
	var content string
	if err := json.Unmarshal(part.Content, &content); err != nil {
		return
	}

	switch part.ContentType {
	case "text/plain":
		if *text == "" {
			*text = content
		}
	case "text/html":
		if *html == "" {
			*html = content
		}
	}
}

// Client defines the interface for notmuch operations
type Client interface {
	// Search searches for messages matching the query
	Search(query string, limit int) ([]SearchResult, error)

	// GetFiles returns file paths for messages matching the query
	GetFiles(query string, limit int) ([]string, error)

	// Tag applies tag changes to messages matching the query
	Tag(query string, tags []string) error

	// ShowThread returns all messages in a thread
	ShowThread(threadID string) ([]ThreadMessage, error)
}

// ExecClient implements Client using exec.Command
type ExecClient struct{}

// NewExecClient creates a new ExecClient
func NewExecClient() *ExecClient {
	return &ExecClient{}
}

// Search executes notmuch search and returns results
func (c *ExecClient) Search(query string, limit int) ([]SearchResult, error) {
	if limit == 0 {
		limit = 50
	}

	cmd := exec.Command("notmuch", "search", "--format=json", "--limit="+strconv.Itoa(limit), query)
	out, err := cmd.Output()
	if err != nil {
		return nil, err
	}

	var results []SearchResult
	if err := json.Unmarshal(out, &results); err != nil {
		return nil, err
	}

	return results, nil
}

// GetFiles returns file paths for messages matching the query
func (c *ExecClient) GetFiles(query string, limit int) ([]string, error) {
	args := []string{"search", "--output=files"}
	if limit > 0 {
		args = append(args, "--limit="+strconv.Itoa(limit))
	}
	args = append(args, query)

	cmd := exec.Command("notmuch", args...)
	out, err := cmd.Output()
	if err != nil {
		return nil, err
	}

	files := strings.Split(strings.TrimSpace(string(out)), "\n")
	if len(files) == 1 && files[0] == "" {
		return nil, nil
	}

	return files, nil
}

// Tag applies tag changes to messages matching the query
func (c *ExecClient) Tag(query string, tags []string) error {
	args := append([]string{"tag"}, tags...)
	args = append(args, "--", query)

	cmd := exec.Command("notmuch", args...)
	return cmd.Run()
}

// ShowThread returns all messages in a thread using notmuch show
func (c *ExecClient) ShowThread(threadID string) ([]ThreadMessage, error) {
	cmd := exec.Command("notmuch", "show", "--format=json", "--include-html", "--entire-thread=true", "thread:"+threadID)
	out, err := cmd.Output()
	if err != nil {
		return nil, err
	}

	// notmuch show returns a deeply nested structure: [[[msg, [replies]], ...]]
	// We need to flatten this into a simple list of messages
	var raw json.RawMessage
	if err := json.Unmarshal(out, &raw); err != nil {
		return nil, err
	}

	var messages []ThreadMessage
	flattenThread(raw, &messages)
	return messages, nil
}

// flattenThread recursively extracts messages from notmuch's nested thread structure
func flattenThread(data json.RawMessage, messages *[]ThreadMessage) {
	// Try to parse as array first
	var arr []json.RawMessage
	if err := json.Unmarshal(data, &arr); err != nil {
		return
	}

	for _, item := range arr {
		// Try to parse as message (has "id" field)
		var msg ThreadMessage
		if err := json.Unmarshal(item, &msg); err == nil && msg.ID != "" {
			*messages = append(*messages, msg)
			continue
		}

		// Otherwise recurse into nested arrays
		flattenThread(item, messages)
	}
}
