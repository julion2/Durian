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
	Subject      string   `json:"subject"`
	Authors      string   `json:"authors"`
	DateRelative string   `json:"date_relative"`
	Tags         []string `json:"tags"`
}

// Client defines the interface for notmuch operations
type Client interface {
	// Search searches for messages matching the query
	Search(query string, limit int) ([]SearchResult, error)

	// GetFiles returns file paths for messages matching the query
	GetFiles(query string, limit int) ([]string, error)

	// Tag applies tag changes to messages matching the query
	Tag(query string, tags []string) error
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
