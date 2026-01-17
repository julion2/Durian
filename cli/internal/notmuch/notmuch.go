// Package notmuch provides a wrapper around the notmuch CLI for tag operations
package notmuch

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// Message represents a notmuch message
type Message struct {
	ID       string   `json:"id"`
	Filename string   `json:"filename"`
	Tags     []string `json:"tags"`
}

// Client wraps the notmuch CLI
type Client struct {
	databasePath string
}

// NewClient creates a new notmuch client
func NewClient(databasePath string) *Client {
	return &Client{
		databasePath: databasePath,
	}
}

// GetMessageByID retrieves a message by its Message-ID
func (c *Client) GetMessageByID(messageID string) (*Message, error) {
	query := fmt.Sprintf("id:%s", messageID)
	messages, err := c.Search(query)
	if err != nil {
		return nil, err
	}
	if len(messages) == 0 {
		return nil, fmt.Errorf("message not found: %s", messageID)
	}
	return messages[0], nil
}

// MessageExists checks if a message with the given Message-ID exists in notmuch
// Returns true if found, false otherwise (no error on not-found)
func (c *Client) MessageExists(messageID string) bool {
	// Use count for efficiency - faster than full search
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

// GetFilenameByMessageID returns the file path for a message by its Message-ID
// Returns empty string if not found (no error)
func (c *Client) GetFilenameByMessageID(messageID string) string {
	args := []string{"search", "--output=files", "--exclude=false", "id:" + messageID}
	if c.databasePath != "" {
		args = append([]string{"--config=" + c.databasePath}, args...)
	}

	cmd := exec.Command("notmuch", args...)
	output, err := cmd.Output()
	if err != nil {
		return ""
	}

	// Return first filename (there might be multiple for duplicates)
	lines := strings.Split(strings.TrimSpace(string(output)), "\n")
	if len(lines) > 0 && lines[0] != "" {
		return lines[0]
	}
	return ""
}

// DeleteMessageFile removes a message file from disk and the notmuch database
// Returns nil if successful or if the message doesn't exist
func (c *Client) DeleteMessageFile(messageID string) error {
	filename := c.GetFilenameByMessageID(messageID)
	if filename == "" {
		return nil // Message not found, nothing to delete
	}

	// Remove the file from disk
	if err := os.Remove(filename); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("failed to remove file %s: %w", filename, err)
	}

	return nil
}

// GetMessageByFilename retrieves a message by its filename (maildir path)
func (c *Client) GetMessageByFilename(filename string) (*Message, error) {
	// notmuch can search by path
	query := fmt.Sprintf("path:%s", filepath.Base(filename))
	messages, err := c.Search(query)
	if err != nil {
		return nil, err
	}

	// Find exact match
	for _, msg := range messages {
		if strings.HasSuffix(msg.Filename, filepath.Base(filename)) ||
			msg.Filename == filename {
			return msg, nil
		}
	}

	return nil, fmt.Errorf("message not found: %s", filename)
}

// Search searches for messages matching the query
// Uses --exclude=false to include messages with excluded tags (deleted, spam)
func (c *Client) Search(query string) ([]*Message, error) {
	// Use notmuch show to get all message info in one go
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

	// notmuch show returns a nested structure: [ [[{msg}, [replies]], ...], ... ]  (array of threads)
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
				continue // Skip malformed messages
			}

			// Use first filename if multiple
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

// showMessage gets full message info using notmuch show
// Uses --exclude=false to include messages with excluded tags (deleted, spam)
func (c *Client) showMessage(messageID string) (*Message, error) {
	args := []string{"show", "--format=json", "--entire-thread=false", "--exclude=false", "id:" + messageID}
	if c.databasePath != "" {
		args = append([]string{"--config=" + c.databasePath}, args...)
	}

	cmd := exec.Command("notmuch", args...)
	output, err := cmd.Output()
	if err != nil {
		return nil, err
	}

	// notmuch show returns a nested structure: [[[message, replies], ...]]
	// The structure is: list of threads -> list of messages -> [message_data, replies]
	var result [][][]json.RawMessage
	if err := json.Unmarshal(output, &result); err != nil {
		return nil, fmt.Errorf("failed to parse show results: %w", err)
	}

	if len(result) == 0 || len(result[0]) == 0 || len(result[0][0]) == 0 {
		return nil, fmt.Errorf("no message found")
	}

	// Parse the first element which is the message data
	var msg showResult
	if err := json.Unmarshal(result[0][0][0], &msg); err != nil {
		return nil, fmt.Errorf("failed to parse message: %w", err)
	}

	// Use first filename if multiple
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

type showResult struct {
	ID       string   `json:"id"`
	Filename []string `json:"filename"` // Can be multiple filenames for duplicates
	Tags     []string `json:"tags"`
}

// GetTags returns the tags for a message
func (c *Client) GetTags(messageID string) ([]string, error) {
	msg, err := c.showMessage(messageID)
	if err != nil {
		return nil, err
	}
	return msg.Tags, nil
}

// AddTags adds tags to messages matching the query
func (c *Client) AddTags(query string, tags ...string) error {
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

// RemoveTags removes tags from messages matching the query
func (c *Client) RemoveTags(query string, tags ...string) error {
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

// ModifyTags adds and removes tags in a single notmuch call
// This is more efficient than separate AddTags/RemoveTags calls
// Example: ModifyTags("id:xxx", []string{"trash"}, []string{"inbox"})
// Results in: notmuch tag +trash -inbox -- id:xxx
func (c *Client) ModifyTags(query string, addTags []string, removeTags []string) error {
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

// SetTags sets tags on messages, replacing existing tags
func (c *Client) SetTags(query string, tags []string) error {
	args := []string{"tag"}
	if c.databasePath != "" {
		args = append([]string{"--config=" + c.databasePath}, args...)
	}

	// First remove all standard tags, then add the new ones
	// We only manage the IMAP-related tags
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

// HasTag checks if a message has a specific tag
func (c *Client) HasTag(messageID, tag string) (bool, error) {
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

// GetAllMessagesWithTags returns all messages in a folder with their tags
// Uses a single notmuch show call instead of individual queries per message
// Returns map[messageID][]tags - much faster than calling GetTags() for each message
func (c *Client) GetAllMessagesWithTags(folder string) (map[string][]string, error) {
	query := fmt.Sprintf("folder:%s", folder)
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

	// Parse the nested JSON structure:
	// [ [[{msg}, [replies]], ...], ... ]  (array of threads)
	var threads [][][]json.RawMessage
	if len(output) > 0 {
		if err := json.Unmarshal(output, &threads); err != nil {
			return nil, fmt.Errorf("failed to parse show results: %w", err)
		}
	}

	result := make(map[string][]string)

	// Extract message ID and tags from each message
	for _, thread := range threads {
		for _, msgPair := range thread {
			if len(msgPair) == 0 {
				continue
			}

			var msg struct {
				ID   string   `json:"id"`
				Tags []string `json:"tags"`
			}
			if err := json.Unmarshal(msgPair[0], &msg); err != nil {
				continue // Skip malformed messages
			}

			if msg.ID != "" {
				result[msg.ID] = msg.Tags
			}
		}
	}

	return result, nil
}

// GetAllMessageIDs returns all message IDs in a mailbox folder
// Uses --exclude=false to include messages with excluded tags (deleted, spam)
// This is important for flag sync to work with deleted messages
func (c *Client) GetAllMessageIDs(folder string) ([]string, error) {
	query := fmt.Sprintf("folder:%s", folder)
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

	// Strip "id:" prefix from message IDs for consistency with IMAP Message-IDs
	for i, id := range messageIDs {
		messageIDs[i] = strings.TrimPrefix(id, "id:")
	}

	return messageIDs, nil
}

// GetMessagesWithTags returns messages that have specific tags in a folder
func (c *Client) GetMessagesWithTags(folder string, tags []string) ([]*Message, error) {
	// Build query: folder:X AND (tag:a OR tag:b OR ...)
	tagQueries := make([]string, len(tags))
	for i, tag := range tags {
		tagQueries[i] = "tag:" + tag
	}
	query := fmt.Sprintf("folder:%s AND (%s)", folder, strings.Join(tagQueries, " OR "))

	return c.Search(query)
}

// RunNew runs "notmuch new" to index new messages
func (c *Client) RunNew() error {
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
