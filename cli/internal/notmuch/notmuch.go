// Package notmuch provides a unified wrapper around the notmuch CLI.
// It covers search/display operations (used by the handler and CLI commands)
// as well as sync operations (used by IMAP sync).
package notmuch

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	internmail "github.com/durian-dev/durian/cli/internal/mail"
	"github.com/durian-dev/durian/cli/internal/sanitize"
)

// ---------- Types ----------

// Message represents a notmuch message (used by sync operations)
type Message struct {
	ID       string   `json:"id"`
	Filename string   `json:"filename"`
	Tags     []string `json:"tags"`
}

// SearchResult represents a single result from notmuch search (used by UI)
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
	ContentLength      int             `json:"content-length"`
	ContentID          string          `json:"content-id,omitempty"`
	Filename           string          `json:"filename,omitempty"`
}

// ---------- Client interface ----------

// Client defines the interface for all notmuch operations.
type Client interface {
	// Search/display operations (used by handler and CLI)
	Search(query string, limit int) ([]SearchResult, error)
	GetFiles(query string, limit int) ([]string, error)
	Tag(query string, tags []string) error
	ShowThread(threadID string) ([]ThreadMessage, error)
	ShowByQuery(query string, limit int) ([][]ThreadMessage, error)
	ShowMessages(query string) ([]ThreadMessage, error)
	ShowRawPart(messageID string, partID int, w io.Writer) error

	// Tag listing
	ListTags() ([]string, error)

	// Message operations (used by sync)
	MessageExists(messageID string) bool
	GetFilenamesByMessageID(messageID string) []string
	DeleteMessageFiles(messageID string) error
	ModifyTags(query string, addTags []string, removeTags []string) error
	GetAllMessagesWithTags(folder string) (map[string][]string, error)
	RunNew() error
}

// ---------- ExecClient implementation ----------

// ExecClient implements Client using the notmuch CLI.
type ExecClient struct {
	databasePath string
}

// NewExecClient creates a new ExecClient.
func NewExecClient(databasePath string) *ExecClient {
	return &ExecClient{databasePath: databasePath}
}

// NewClient is an alias for NewExecClient for backwards compatibility.
func NewClient(databasePath string) *ExecClient {
	return NewExecClient(databasePath)
}

// ---------- Search/display methods (from backend/notmuch) ----------

// Search executes notmuch search and returns results for UI display.
func (c *ExecClient) Search(query string, limit int) ([]SearchResult, error) {
	if limit == 0 {
		limit = 50
	}

	args := []string{"search", "--format=json", "--limit=" + strconv.Itoa(limit)}
	if c.databasePath != "" {
		args = append([]string{"--config=" + c.databasePath}, args...)
	}
	args = append(args, query)

	cmd := exec.Command("notmuch", args...)
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

// GetFiles returns file paths for messages matching the query.
func (c *ExecClient) GetFiles(query string, limit int) ([]string, error) {
	args := []string{"search", "--output=files"}
	if c.databasePath != "" {
		args = append([]string{"--config=" + c.databasePath}, args...)
	}
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

// Tag applies tag changes to messages matching the query.
// Tags are in notmuch format, e.g., ["+inbox", "-unread"].
func (c *ExecClient) Tag(query string, tags []string) error {
	args := []string{"tag"}
	if c.databasePath != "" {
		args = append([]string{"--config=" + c.databasePath}, args...)
	}
	args = append(args, tags...)
	args = append(args, "--", query)

	cmd := exec.Command("notmuch", args...)
	return cmd.Run()
}

// ShowThread returns all messages in a thread using notmuch show.
func (c *ExecClient) ShowThread(threadID string) ([]ThreadMessage, error) {
	args := []string{"show", "--format=json", "--include-html", "--entire-thread=true"}
	if c.databasePath != "" {
		args = append([]string{"--config=" + c.databasePath}, args...)
	}
	args = append(args, "thread:"+threadID)

	cmd := exec.Command("notmuch", args...)
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

// ShowByQuery runs notmuch show with an arbitrary query and returns messages
// grouped by thread. Each inner slice contains the flattened messages of one thread,
// in the same order as notmuch search would return them.
func (c *ExecClient) ShowByQuery(query string, limit int) ([][]ThreadMessage, error) {
	args := []string{"show", "--format=json", "--include-html", "--entire-thread=true"}
	if limit > 0 {
		args = append(args, "--limit="+strconv.Itoa(limit))
	}
	if c.databasePath != "" {
		args = append([]string{"--config=" + c.databasePath}, args...)
	}
	args = append(args, query)

	cmd := exec.Command("notmuch", args...)
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("notmuch show failed: %w", err)
	}

	// Top-level is an array of thread groups
	var topLevel []json.RawMessage
	if err := json.Unmarshal(out, &topLevel); err != nil {
		return nil, fmt.Errorf("failed to parse show results: %w", err)
	}

	result := make([][]ThreadMessage, 0, len(topLevel))
	for _, threadRaw := range topLevel {
		var msgs []ThreadMessage
		flattenThread(threadRaw, &msgs)
		if len(msgs) > 0 {
			result = append(result, msgs)
		}
	}
	return result, nil
}

// ShowMessages returns individual messages matching a query (no thread expansion).
// Unlike ShowThread, this uses --entire-thread=false so only the matched messages
// are returned, not their entire threads. Useful for fetching bodies of specific
// messages by ID (e.g. "id:xxx OR id:yyy").
func (c *ExecClient) ShowMessages(query string) ([]ThreadMessage, error) {
	args := []string{"show", "--format=json", "--include-html", "--entire-thread=false"}
	if c.databasePath != "" {
		args = append([]string{"--config=" + c.databasePath}, args...)
	}
	args = append(args, query)

	cmd := exec.Command("notmuch", args...)
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("notmuch show failed: %w", err)
	}

	var raw json.RawMessage
	if err := json.Unmarshal(out, &raw); err != nil {
		return nil, fmt.Errorf("failed to parse show results: %w", err)
	}

	var messages []ThreadMessage
	flattenThread(raw, &messages)
	return messages, nil
}

// ShowRawPart streams a single MIME part's raw bytes from a message.
// Uses notmuch show --format=raw --part=N to extract the part without buffering.
func (c *ExecClient) ShowRawPart(messageID string, partID int, w io.Writer) error {
	args := []string{"show", "--format=raw", "--part=" + strconv.Itoa(partID)}
	if c.databasePath != "" {
		args = append([]string{"--config=" + c.databasePath}, args...)
	}
	args = append(args, "id:"+messageID)

	cmd := exec.Command("notmuch", args...)
	cmd.Stdout = w
	return cmd.Run()
}

// ListTags returns all tags known to notmuch.
func (c *ExecClient) ListTags() ([]string, error) {
	args := []string{"search", "--output=tags", "*"}
	if c.databasePath != "" {
		args = append([]string{"--config=" + c.databasePath}, args...)
	}

	cmd := exec.Command("notmuch", args...)
	out, err := cmd.Output()
	if err != nil {
		return nil, err
	}

	trimmed := strings.TrimSpace(string(out))
	if trimmed == "" {
		return nil, nil
	}
	return strings.Split(trimmed, "\n"), nil
}

// ---------- Sync/message methods (from internal/notmuch) ----------

// GetMessageByID retrieves a message by its Message-ID.
func (c *ExecClient) GetMessageByID(messageID string) (*Message, error) {
	query := fmt.Sprintf("id:%s", messageID)
	messages, err := c.searchMessages(query)
	if err != nil {
		return nil, err
	}
	if len(messages) == 0 {
		return nil, fmt.Errorf("message not found: %s", messageID)
	}
	return messages[0], nil
}

// MessageExists checks if a message with the given Message-ID exists in notmuch.
func (c *ExecClient) MessageExists(messageID string) bool {
	args := []string{"count", "--exclude=false", "id:" + messageID}
	if c.databasePath != "" {
		args = append([]string{"--config=" + c.databasePath}, args...)
	}

	cmd := exec.Command("notmuch", args...)
	output, err := cmd.Output()
	if err != nil {
		return false
	}

	count := strings.TrimSpace(string(output))
	return count != "0" && count != ""
}

// GetFilenameByMessageID returns the first file path for a message by its Message-ID.
// Returns empty string if not found.
func (c *ExecClient) GetFilenameByMessageID(messageID string) string {
	filenames := c.GetFilenamesByMessageID(messageID)
	if len(filenames) > 0 {
		return filenames[0]
	}
	return ""
}

// GetFilenamesByMessageID returns all file paths for a message by its Message-ID.
// A message can have multiple files when it exists in multiple maildir folders.
func (c *ExecClient) GetFilenamesByMessageID(messageID string) []string {
	args := []string{"search", "--output=files", "--exclude=false", "id:" + messageID}
	if c.databasePath != "" {
		args = append([]string{"--config=" + c.databasePath}, args...)
	}

	cmd := exec.Command("notmuch", args...)
	output, err := cmd.Output()
	if err != nil {
		return nil
	}

	return parseFilenames(string(output))
}

// DeleteMessageFile removes files for a message from disk.
// Deprecated: Use DeleteMessageFiles.
func (c *ExecClient) DeleteMessageFile(messageID string) error {
	return c.DeleteMessageFiles(messageID)
}

// DeleteMessageFiles removes all files for a message from disk.
// Messages can have multiple files when they exist in multiple maildir folders.
func (c *ExecClient) DeleteMessageFiles(messageID string) error {
	filenames := c.GetFilenamesByMessageID(messageID)
	if len(filenames) == 0 {
		return nil
	}

	var firstErr error
	for _, filename := range filenames {
		if err := os.Remove(filename); err != nil && !os.IsNotExist(err) {
			if firstErr == nil {
				firstErr = fmt.Errorf("failed to remove file %s: %w", filename, err)
			}
		}
	}
	return firstErr
}

// GetMessageByFilename retrieves a message by its filename (maildir path).
func (c *ExecClient) GetMessageByFilename(filename string) (*Message, error) {
	query := fmt.Sprintf("path:%s", filepath.Base(filename))
	messages, err := c.searchMessages(query)
	if err != nil {
		return nil, err
	}

	for _, msg := range messages {
		if strings.HasSuffix(msg.Filename, filepath.Base(filename)) ||
			msg.Filename == filename {
			return msg, nil
		}
	}

	return nil, fmt.Errorf("message not found: %s", filename)
}

// GetTags returns the tags for a message.
func (c *ExecClient) GetTags(messageID string) ([]string, error) {
	msg, err := c.showMessage(messageID)
	if err != nil {
		return nil, err
	}
	return msg.Tags, nil
}

// AddTags adds tags to messages matching the query.
func (c *ExecClient) AddTags(query string, tags ...string) error {
	if len(tags) == 0 {
		return nil
	}

	args := []string{"tag"}
	if c.databasePath != "" {
		args = append([]string{"--config=" + c.databasePath}, args...)
	}

	for _, tag := range tags {
		args = append(args, "+"+tag)
	}
	args = append(args, "--", query)

	cmd := exec.Command("notmuch", args...)
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("notmuch tag failed: %s", string(output))
	}

	return nil
}

// RemoveTags removes tags from messages matching the query.
func (c *ExecClient) RemoveTags(query string, tags ...string) error {
	if len(tags) == 0 {
		return nil
	}

	args := []string{"tag"}
	if c.databasePath != "" {
		args = append([]string{"--config=" + c.databasePath}, args...)
	}

	for _, tag := range tags {
		args = append(args, "-"+tag)
	}
	args = append(args, "--", query)

	cmd := exec.Command("notmuch", args...)
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("notmuch tag failed: %s", string(output))
	}

	return nil
}

// ModifyTags adds and removes tags in a single notmuch call.
func (c *ExecClient) ModifyTags(query string, addTags []string, removeTags []string) error {
	if len(addTags) == 0 && len(removeTags) == 0 {
		return nil
	}

	args := []string{"tag"}
	if c.databasePath != "" {
		args = append([]string{"--config=" + c.databasePath}, args...)
	}

	for _, tag := range addTags {
		args = append(args, "+"+tag)
	}
	for _, tag := range removeTags {
		args = append(args, "-"+tag)
	}
	args = append(args, "--", query)

	cmd := exec.Command("notmuch", args...)
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("notmuch tag failed: %s", string(output))
	}

	return nil
}

// SetTags sets tags on messages, replacing existing IMAP-related tags.
func (c *ExecClient) SetTags(query string, tags []string) error {
	args := []string{"tag"}
	if c.databasePath != "" {
		args = append([]string{"--config=" + c.databasePath}, args...)
	}

	args = append(args, "-unread", "-flagged", "-replied", "-deleted")
	for _, tag := range tags {
		args = append(args, "+"+tag)
	}
	args = append(args, "--", query)

	cmd := exec.Command("notmuch", args...)
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("notmuch tag failed: %s", string(output))
	}

	return nil
}

// HasTag checks if a message has a specific tag.
func (c *ExecClient) HasTag(messageID, tag string) (bool, error) {
	tags, err := c.GetTags(messageID)
	if err != nil {
		return false, err
	}

	for _, t := range tags {
		if t == tag {
			return true, nil
		}
	}
	return false, nil
}

// GetAllMessagesWithTags returns all messages in a folder with their tags.
// Uses a single notmuch show call. Returns map[messageID][]tags.
func (c *ExecClient) GetAllMessagesWithTags(folder string) (map[string][]string, error) {
	query := fmt.Sprintf("folder:\"%s\"", folder)
	args := []string{"show", "--format=json", "--entire-thread=false",
		"--body=false", "--exclude=false", query}
	if c.databasePath != "" {
		args = append([]string{"--config=" + c.databasePath}, args...)
	}

	cmd := exec.Command("notmuch", args...)
	output, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("notmuch show failed: %w", err)
	}

	result := make(map[string][]string)
	if len(output) > 0 {
		var raw json.RawMessage
		if err := json.Unmarshal(output, &raw); err != nil {
			return nil, fmt.Errorf("failed to parse show results: %w", err)
		}
		extractMessages(raw, result)
	}

	return result, nil
}

// GetAllMessageIDs returns all message IDs in a mailbox folder.
func (c *ExecClient) GetAllMessageIDs(folder string) ([]string, error) {
	query := fmt.Sprintf("folder:\"%s\"", folder)
	args := []string{"search", "--exclude=false", "--output=messages", "--format=json", query}
	if c.databasePath != "" {
		args = append([]string{"--config=" + c.databasePath}, args...)
	}

	cmd := exec.Command("notmuch", args...)
	output, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("notmuch search failed: %w", err)
	}

	var messageIDs []string
	if len(output) > 0 {
		if err := json.Unmarshal(output, &messageIDs); err != nil {
			return nil, fmt.Errorf("failed to parse search results: %w", err)
		}
	}

	for i, id := range messageIDs {
		messageIDs[i] = strings.TrimPrefix(id, "id:")
	}

	return messageIDs, nil
}

// GetMessagesWithTags returns messages that have specific tags in a folder.
func (c *ExecClient) GetMessagesWithTags(folder string, tags []string) ([]*Message, error) {
	tagQueries := make([]string, len(tags))
	for i, tag := range tags {
		tagQueries[i] = "tag:" + tag
	}
	query := fmt.Sprintf("folder:\"%s\" AND (%s)", folder, strings.Join(tagQueries, " OR "))

	return c.searchMessages(query)
}

// RunNew runs "notmuch new" to index new messages.
func (c *ExecClient) RunNew() error {
	args := []string{"new"}
	if c.databasePath != "" {
		args = append([]string{"--config=" + c.databasePath}, args...)
	}

	cmd := exec.Command("notmuch", args...)
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("notmuch new failed: %s", string(output))
	}

	return nil
}

// ---------- Pure functions (from backend/notmuch) ----------

// ExtractBodyContent extracts text/plain, text/html and attachments from a message.
// HTML content is stripped of quoted reply content to avoid duplicates in thread view.
func ExtractBodyContent(body []json.RawMessage) (text, html string, attachments []internmail.AttachmentInfo) {
	for _, raw := range body {
		extractFromRaw(raw, &text, &html, &attachments)
	}
	html = StripQuotedContent(html)
	html = sanitize.SanitizeHTML(html)
	return
}

// ExtractBodyContentFull extracts text/plain, text/html and attachments from a message.
// Unlike ExtractBodyContent, it does NOT strip quoted reply content — used for reply
// quoting where the full conversation chain must be preserved.
func ExtractBodyContentFull(body []json.RawMessage) (text, html string, attachments []internmail.AttachmentInfo) {
	for _, raw := range body {
		extractFromRaw(raw, &text, &html, &attachments)
	}
	html = sanitize.SanitizeHTML(html)
	return
}

// quotePatterns defines HTML patterns that indicate quoted/forwarded content.
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

	// Generic blockquote (fallback)
	`<blockquote`,
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

	if earliestIdx == -1 {
		return html
	}

	stripped := html[:earliestIdx]
	stripped = strings.TrimRight(stripped, " \t\n\r")

	return stripped
}

// ---------- Internal helpers ----------

func extractFromRaw(raw json.RawMessage, text, html *string, attachments *[]internmail.AttachmentInfo) {
	var part BodyPart
	if err := json.Unmarshal(raw, &part); err != nil {
		return
	}

	// Capture any part with a filename as an attachment (inline or explicit)
	if part.Filename != "" {
		disposition := part.ContentDisposition
		if disposition == "" {
			disposition = "attachment"
		}
		*attachments = append(*attachments, internmail.AttachmentInfo{
			PartID:      part.ID,
			Filename:    part.Filename,
			ContentType: part.ContentType,
			Size:        part.ContentLength,
			Disposition: disposition,
			ContentID:   part.ContentID,
		})
		return
	}

	if strings.HasPrefix(part.ContentType, "multipart/") {
		var subParts []json.RawMessage
		if err := json.Unmarshal(part.Content, &subParts); err == nil {
			for _, sub := range subParts {
				extractFromRaw(sub, text, html, attachments)
			}
		}
		return
	}

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

// flattenThread recursively extracts messages from notmuch's nested thread structure.
func flattenThread(data json.RawMessage, messages *[]ThreadMessage) {
	var arr []json.RawMessage
	if err := json.Unmarshal(data, &arr); err != nil {
		return
	}

	for _, item := range arr {
		var msg ThreadMessage
		if err := json.Unmarshal(item, &msg); err == nil && msg.ID != "" {
			*messages = append(*messages, msg)
			continue
		}
		flattenThread(item, messages)
	}
}

// parseFilenames splits notmuch --output=files output into non-empty filenames.
func parseFilenames(output string) []string {
	trimmed := strings.TrimSpace(output)
	if trimmed == "" {
		return nil
	}
	lines := strings.Split(trimmed, "\n")
	var result []string
	for _, line := range lines {
		if line != "" {
			result = append(result, line)
		}
	}
	return result
}

// searchMessages searches for messages using notmuch show (internal helper).
// This is different from Search which uses notmuch search for UI results.
func (c *ExecClient) searchMessages(query string) ([]*Message, error) {
	args := []string{"show", "--format=json", "--entire-thread=false", "--exclude=false", query}
	if c.databasePath != "" {
		args = append([]string{"--config=" + c.databasePath}, args...)
	}

	cmd := exec.Command("notmuch", args...)
	output, err := cmd.Output()
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			return nil, fmt.Errorf("notmuch show failed: %s", string(exitErr.Stderr))
		}
		return nil, fmt.Errorf("notmuch show failed: %w", err)
	}

	var threads [][][]json.RawMessage
	if len(output) > 0 {
		if err := json.Unmarshal(output, &threads); err != nil {
			return nil, fmt.Errorf("failed to parse show results: %w", err)
		}
	}

	var messages []*Message
	for _, thread := range threads {
		for _, msgPair := range thread {
			if len(msgPair) == 0 {
				continue
			}

			var msg showResult
			if err := json.Unmarshal(msgPair[0], &msg); err != nil {
				continue
			}

			filename := ""
			if len(msg.Filename) > 0 {
				filename = msg.Filename[0]
			}

			messages = append(messages, &Message{
				ID:       msg.ID,
				Filename: filename,
				Tags:     msg.Tags,
			})
		}
	}

	return messages, nil
}

// showMessage gets full message info using notmuch show.
func (c *ExecClient) showMessage(messageID string) (*Message, error) {
	args := []string{"show", "--format=json", "--entire-thread=false", "--exclude=false", "id:" + messageID}
	if c.databasePath != "" {
		args = append([]string{"--config=" + c.databasePath}, args...)
	}

	cmd := exec.Command("notmuch", args...)
	output, err := cmd.Output()
	if err != nil {
		return nil, err
	}

	var result [][][]json.RawMessage
	if err := json.Unmarshal(output, &result); err != nil {
		return nil, fmt.Errorf("failed to parse show results: %w", err)
	}

	if len(result) == 0 || len(result[0]) == 0 || len(result[0][0]) == 0 {
		return nil, fmt.Errorf("no message found")
	}

	var msg showResult
	if err := json.Unmarshal(result[0][0][0], &msg); err != nil {
		return nil, fmt.Errorf("failed to parse message: %w", err)
	}

	filename := ""
	if len(msg.Filename) > 0 {
		filename = msg.Filename[0]
	}

	return &Message{
		ID:       msg.ID,
		Filename: filename,
		Tags:     msg.Tags,
	}, nil
}

// extractMessages recursively walks the notmuch show JSON tree and extracts
// message id/tags from every message object it finds.
func extractMessages(raw json.RawMessage, result map[string][]string) {
	var msg struct {
		ID   string   `json:"id"`
		Tags []string `json:"tags"`
	}
	if err := json.Unmarshal(raw, &msg); err == nil && msg.ID != "" {
		result[msg.ID] = msg.Tags
		return
	}

	var arr []json.RawMessage
	if err := json.Unmarshal(raw, &arr); err == nil {
		for _, item := range arr {
			extractMessages(item, result)
		}
	}
}

type showResult struct {
	ID       string   `json:"id"`
	Filename []string `json:"filename"`
	Tags     []string `json:"tags"`
}
