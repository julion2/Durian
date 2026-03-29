// Package tagsync provides a client for the optional Durian Tag Sync Server.
// It pushes local tag changes and pulls remote changes for multi-machine sync.
package tagsync

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// TagChange represents a single tag add/remove event.
type TagChange struct {
	MessageID string `json:"message_id"`
	Account   string `json:"account"`
	Tag       string `json:"tag"`
	Action    string `json:"action"` // "add" or "remove"
	Timestamp int64  `json:"timestamp"`
	ClientID  string `json:"client_id,omitempty"`
}

// Client communicates with the tag sync server.
type Client struct {
	url      string
	apiKey   string
	clientID string
	http     *http.Client
}

// NewClient creates a new tag sync client.
func NewClient(url, apiKey string) *Client {
	return &Client{
		url:      strings.TrimRight(url, "/"),
		apiKey:   apiKey,
		clientID: getClientID(),
		http:     &http.Client{Timeout: 10 * time.Second},
	}
}

// Push sends local tag changes to the sync server.
func (c *Client) Push(changes []TagChange) error {
	if len(changes) == 0 {
		return nil
	}

	for i := range changes {
		changes[i].ClientID = c.clientID
		if changes[i].Timestamp == 0 {
			changes[i].Timestamp = time.Now().Unix()
		}
	}

	body, err := json.Marshal(map[string]any{
		"changes":   changes,
		"client_id": c.clientID,
	})
	if err != nil {
		return fmt.Errorf("marshal: %w", err)
	}

	req, err := http.NewRequest("POST", c.url+"/v1/sync", bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-API-Key", c.apiKey)

	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("sync push: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("sync push failed (%d): %s", resp.StatusCode, string(b))
	}

	slog.Debug("Tag sync push complete", "module", "TAGSYNC", "changes", len(changes))
	return nil
}

// Pull fetches remote tag changes since the given timestamp.
// Returns the changes and the server timestamp to use for the next pull.
func (c *Client) Pull(since int64) ([]TagChange, int64, error) {
	pullURL := fmt.Sprintf("%s/sync?since=%s&client_id=%s",
		c.url, strconv.FormatInt(since, 10), url.QueryEscape(c.clientID))

	req, err := http.NewRequest("GET", pullURL, nil)
	if err != nil {
		return nil, since, fmt.Errorf("request: %w", err)
	}
	req.Header.Set("X-API-Key", c.apiKey)

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, since, fmt.Errorf("sync pull: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(resp.Body)
		return nil, since, fmt.Errorf("sync pull failed (%d): %s", resp.StatusCode, string(b))
	}

	var result struct {
		Changes []TagChange `json:"changes"`
		SyncAt  int64       `json:"sync_at"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, since, fmt.Errorf("decode: %w", err)
	}

	slog.Debug("Tag sync pull complete", "module", "TAGSYNC", "changes", len(result.Changes))
	return result.Changes, result.SyncAt, nil
}

// LoadLastSync reads the last sync timestamp from disk.
func (c *Client) LoadLastSync() int64 {
	home, _ := os.UserHomeDir()
	data, err := os.ReadFile(filepath.Join(home, ".config", "durian", "tag_sync_at"))
	if err != nil {
		return 0
	}
	ts, _ := strconv.ParseInt(strings.TrimSpace(string(data)), 10, 64)
	return ts
}

// SaveLastSync persists the sync timestamp to disk.
func (c *Client) SaveLastSync(ts int64) {
	home, _ := os.UserHomeDir()
	_ = os.WriteFile(
		filepath.Join(home, ".config", "durian", "tag_sync_at"),
		[]byte(strconv.FormatInt(ts, 10)),
		0600,
	)
}

// getClientID returns a stable per-machine identifier.
func getClientID() string {
	hostname, err := os.Hostname()
	if err != nil {
		hostname = "unknown"
	}
	home, _ := os.UserHomeDir()
	idFile := filepath.Join(home, ".config", "durian", "client_id")
	if data, err := os.ReadFile(idFile); err == nil {
		return string(data)
	}
	// Generate from hostname
	id := hostname
	_ = os.WriteFile(idFile, []byte(id), 0600)
	return id
}
