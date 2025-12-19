// Package notmuch provides a wrapper around the notmuch CLI for tag operations
package notmuch

import (
	"encoding/json"
	"fmt"
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
func (c *Client) Search(query string) ([]*Message, error) {
	args := []string{"search", "--output=messages", "--format=json", query}
	if c.databasePath != "" {
		args = append([]string{"--config=" + c.databasePath}, args...)
	}

	cmd := exec.Command("notmuch", args...)
	output, err := cmd.Output()
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			return nil, fmt.Errorf("notmuch search failed: %s", string(exitErr.Stderr))
		}
		return nil, fmt.Errorf("notmuch search failed: %w", err)
	}

	// Parse message IDs
	var messageIDs []string
	if len(output) > 0 {
		if err := json.Unmarshal(output, &messageIDs); err != nil {
			return nil, fmt.Errorf("failed to parse search results: %w", err)
		}
	}

	// Get full message info for each ID
	var messages []*Message
	for _, id := range messageIDs {
		msg, err := c.showMessage(id)
		if err != nil {
			continue // Skip messages we can't show
		}
		messages = append(messages, msg)
	}

	return messages, nil
}

// showMessage gets full message info using notmuch show
func (c *Client) showMessage(messageID string) (*Message, error) {
	args := []string{"show", "--format=json", "--entire-thread=false", "id:" + messageID}
	if c.databasePath != "" {
		args = append([]string{"--config=" + c.databasePath}, args...)
	}

	cmd := exec.Command("notmuch", args...)
	output, err := cmd.Output()
	if err != nil {
		return nil, err
	}

	// notmuch show returns a nested structure: [[[ message ]]]
	var result [][]*showResult
	if err := json.Unmarshal(output, &result); err != nil {
		return nil, fmt.Errorf("failed to parse show results: %w", err)
	}

	if len(result) == 0 || len(result[0]) == 0 {
		return nil, fmt.Errorf("no message found")
	}

	msg := result[0][0]
	return &Message{
		ID:       msg.ID,
		Filename: msg.Filename,
		Tags:     msg.Tags,
	}, nil
}

type showResult struct {
	ID       string   `json:"id"`
	Filename string   `json:"filename"`
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

// GetAllMessageIDs returns all message IDs in a mailbox folder
func (c *Client) GetAllMessageIDs(folder string) ([]string, error) {
	query := fmt.Sprintf("folder:%s", folder)
	args := []string{"search", "--output=messages", "--format=json", query}
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
