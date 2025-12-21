package imap

import (
	"bytes"
	"crypto/tls"
	"fmt"
	"net"
	"strings"
	"time"

	"github.com/emersion/go-imap"
	"github.com/emersion/go-imap/client"
	"github.com/emersion/go-sasl"

	"github.com/durian-dev/durian/cli/internal/config"
	"github.com/durian-dev/durian/cli/internal/debug"
	"github.com/durian-dev/durian/cli/internal/keychain"
	"github.com/durian-dev/durian/cli/internal/oauth"
)

const (
	// DefaultTimeout for IMAP operations
	DefaultTimeout = 30 * time.Second
)

// Client wraps an IMAP client connection
type Client struct {
	account *config.AccountConfig
	conn    *client.Client
	timeout time.Duration
}

// NewClient creates a new IMAP client for the given account
func NewClient(account *config.AccountConfig) *Client {
	return &Client{
		account: account,
		timeout: DefaultTimeout,
	}
}

// Connect establishes a TLS connection to the IMAP server
func (c *Client) Connect() error {
	addr := fmt.Sprintf("%s:%d", c.account.IMAP.Host, c.account.IMAP.Port)

	// Connect with timeout
	dialer := &net.Dialer{Timeout: c.timeout}
	conn, err := dialer.Dial("tcp", addr)
	if err != nil {
		return fmt.Errorf("failed to connect to %s: %w", addr, err)
	}

	// Wrap with TLS (IMAPS - port 993)
	tlsConfig := &tls.Config{
		ServerName: c.account.IMAP.Host,
	}
	tlsConn := tls.Client(conn, tlsConfig)

	// Create IMAP client
	c.conn, err = client.New(tlsConn)
	if err != nil {
		conn.Close()
		return fmt.Errorf("failed to create IMAP client: %w", err)
	}

	return nil
}

// Authenticate authenticates with the IMAP server using OAuth2 or password
func (c *Client) Authenticate() error {
	if c.conn == nil {
		return fmt.Errorf("not connected")
	}

	switch c.account.IMAP.Auth {
	case "oauth2":
		return c.authenticateOAuth2()
	case "password", "":
		return c.authenticatePassword()
	default:
		return fmt.Errorf("unsupported auth method: %s", c.account.IMAP.Auth)
	}
}

// authenticateOAuth2 authenticates using XOAUTH2
func (c *Client) authenticateOAuth2() error {
	// Get valid OAuth token (auto-refreshes if needed)
	token, err := oauth.GetValidToken(
		c.account.Email,
		c.account.OAuth.ClientID,
		c.account.OAuth.ClientSecret,
		c.account.OAuth.Tenant,
	)
	if err != nil {
		return fmt.Errorf("failed to get OAuth token: %w", err)
	}

	// Create XOAUTH2 SASL client
	saslClient := NewXOAuth2Client(c.account.Email, token.AccessToken)

	// Authenticate
	if err := c.conn.Authenticate(saslClient); err != nil {
		return fmt.Errorf("XOAUTH2 authentication failed: %w", err)
	}

	return nil
}

// authenticatePassword authenticates using PLAIN/LOGIN
func (c *Client) authenticatePassword() error {
	username := c.account.Auth.Username
	if username == "" {
		username = c.account.Email
	}

	// Get password from unified keychain service
	password, err := keychain.GetPassword("durian-password", c.account.Email)
	if err != nil {
		return fmt.Errorf("failed to get password: %w\nRun: durian auth login %s", err, c.account.Email)
	}

	// Try PLAIN auth first
	if ok, _ := c.conn.Support("AUTH=PLAIN"); ok {
		saslClient := sasl.NewPlainClient("", username, password)
		if err := c.conn.Authenticate(saslClient); err != nil {
			return fmt.Errorf("PLAIN authentication failed: %w", err)
		}
		return nil
	}

	// Fall back to LOGIN
	if err := c.conn.Login(username, password); err != nil {
		return fmt.Errorf("LOGIN authentication failed: %w", err)
	}

	return nil
}

// ListMailboxes returns all mailboxes on the server
func (c *Client) ListMailboxes() ([]*imap.MailboxInfo, error) {
	if c.conn == nil {
		return nil, fmt.Errorf("not connected")
	}

	mailboxes := make(chan *imap.MailboxInfo, 100)
	done := make(chan error, 1)

	go func() {
		done <- c.conn.List("", "*", mailboxes)
	}()

	var result []*imap.MailboxInfo
	for mbox := range mailboxes {
		result = append(result, mbox)
	}

	if err := <-done; err != nil {
		return nil, fmt.Errorf("failed to list mailboxes: %w", err)
	}

	return result, nil
}

// SelectMailbox selects a mailbox (read-write)
func (c *Client) SelectMailbox(name string) (*imap.MailboxStatus, error) {
	if c.conn == nil {
		return nil, fmt.Errorf("not connected")
	}

	status, err := c.conn.Select(name, false)
	if err != nil {
		return nil, fmt.Errorf("failed to select mailbox %s: %w", name, err)
	}

	return status, nil
}

// SearchAll returns all message UIDs in the current mailbox
func (c *Client) SearchAll() ([]uint32, error) {
	if c.conn == nil {
		return nil, fmt.Errorf("not connected")
	}

	criteria := imap.NewSearchCriteria()
	criteria.WithoutFlags = []string{} // Search all messages

	uids, err := c.conn.UidSearch(criteria)
	if err != nil {
		return nil, fmt.Errorf("failed to search messages: %w", err)
	}

	return uids, nil
}

// FetchMessages fetches messages by UID
func (c *Client) FetchMessages(uids []uint32) ([]*imap.Message, error) {
	if c.conn == nil {
		return nil, fmt.Errorf("not connected")
	}

	if len(uids) == 0 {
		return nil, nil
	}

	seqSet := new(imap.SeqSet)
	for _, uid := range uids {
		seqSet.AddNum(uid)
	}

	// Fetch full message (headers + body)
	items := []imap.FetchItem{
		imap.FetchUid,
		imap.FetchFlags,
		imap.FetchInternalDate,
		imap.FetchRFC822,
	}

	debug.Log("FetchMessages: fetching %d UIDs with items: %v", len(uids), items)

	messages := make(chan *imap.Message, len(uids))
	done := make(chan error, 1)

	go func() {
		done <- c.conn.UidFetch(seqSet, items, messages)
	}()

	var result []*imap.Message
	for msg := range messages {
		debug.Log("FetchMessages: received UID %d, Body map size: %d", msg.Uid, len(msg.Body))
		result = append(result, msg)
	}

	if err := <-done; err != nil {
		debug.Log("FetchMessages: error: %v", err)
		return nil, fmt.Errorf("failed to fetch messages: %w", err)
	}

	debug.Log("FetchMessages: completed, got %d messages", len(result))
	return result, nil
}

// Idle starts IDLE mode and returns when there's an update or the stop channel is closed
func (c *Client) Idle(stop <-chan struct{}, updates chan<- bool) error {
	if c.conn == nil {
		return fmt.Errorf("not connected")
	}

	// Set up updates channel
	updatesChan := make(chan client.Update, 10)
	c.conn.Updates = updatesChan

	// Start IDLE in a goroutine
	done := make(chan error, 1)
	go func() {
		done <- c.conn.Idle(stop, nil)
	}()

	// Wait for updates or completion
	for {
		select {
		case update := <-updatesChan:
			switch update.(type) {
			case *client.MailboxUpdate, *client.ExpungeUpdate, *client.MessageUpdate:
				updates <- true
			}
		case err := <-done:
			return err
		}
	}
}

// FetchFlags fetches only flags for the given UIDs (faster than full fetch)
func (c *Client) FetchFlags(uids []uint32) (map[uint32][]string, error) {
	if c.conn == nil {
		return nil, fmt.Errorf("not connected")
	}

	if len(uids) == 0 {
		return make(map[uint32][]string), nil
	}

	seqSet := new(imap.SeqSet)
	for _, uid := range uids {
		seqSet.AddNum(uid)
	}

	// Fetch only UID and FLAGS (much faster than full message)
	items := []imap.FetchItem{
		imap.FetchUid,
		imap.FetchFlags,
	}

	messages := make(chan *imap.Message, len(uids))
	done := make(chan error, 1)

	go func() {
		done <- c.conn.UidFetch(seqSet, items, messages)
	}()

	result := make(map[uint32][]string)
	for msg := range messages {
		result[msg.Uid] = msg.Flags
	}

	if err := <-done; err != nil {
		return nil, fmt.Errorf("failed to fetch flags: %w", err)
	}

	return result, nil
}

// StoreFlags sets flags on a message (replaces existing flags)
func (c *Client) StoreFlags(uid uint32, flags []string) error {
	if c.conn == nil {
		return fmt.Errorf("not connected")
	}

	seqSet := new(imap.SeqSet)
	seqSet.AddNum(uid)

	// Use FLAGS.SILENT to set flags without response
	item := imap.FormatFlagsOp(imap.SetFlags, true)

	// Convert []string to []interface{} - go-imap requires this type
	ifaceFlags := make([]interface{}, len(flags))
	for i, f := range flags {
		ifaceFlags[i] = f
	}

	messages := make(chan *imap.Message, 10)
	done := make(chan error, 1)

	go func() {
		done <- c.conn.UidStore(seqSet, item, ifaceFlags, messages)
	}()

	// Drain any messages
	for range messages {
	}

	if err := <-done; err != nil {
		return fmt.Errorf("failed to store flags for UID %d: %w", uid, err)
	}

	return nil
}

// AddFlags adds flags to a message (keeps existing flags)
func (c *Client) AddFlags(uid uint32, flags []string) error {
	if c.conn == nil {
		return fmt.Errorf("not connected")
	}

	if len(flags) == 0 {
		return nil
	}

	seqSet := new(imap.SeqSet)
	seqSet.AddNum(uid)

	item := imap.FormatFlagsOp(imap.AddFlags, true) // .SILENT - no response

	// Convert []string to []interface{} - go-imap requires this type
	ifaceFlags := make([]interface{}, len(flags))
	for i, f := range flags {
		ifaceFlags[i] = f
	}

	messages := make(chan *imap.Message, 10)
	done := make(chan error, 1)

	go func() {
		done <- c.conn.UidStore(seqSet, item, ifaceFlags, messages)
	}()

	// Drain the channel (should be empty with SILENT)
	for range messages {
	}

	if err := <-done; err != nil {
		return fmt.Errorf("failed to add flags for UID %d: %w", uid, err)
	}

	return nil
}

// RemoveFlags removes flags from a message
func (c *Client) RemoveFlags(uid uint32, flags []string) error {
	if c.conn == nil {
		return fmt.Errorf("not connected")
	}

	if len(flags) == 0 {
		return nil
	}

	seqSet := new(imap.SeqSet)
	seqSet.AddNum(uid)

	item := imap.FormatFlagsOp(imap.RemoveFlags, true) // .SILENT - no response

	// Convert []string to []interface{} - go-imap requires this type
	ifaceFlags := make([]interface{}, len(flags))
	for i, f := range flags {
		ifaceFlags[i] = f
	}

	messages := make(chan *imap.Message, 10)
	done := make(chan error, 1)

	go func() {
		done <- c.conn.UidStore(seqSet, item, ifaceFlags, messages)
	}()

	// Drain the channel (should be empty with SILENT)
	for range messages {
	}

	if err := <-done; err != nil {
		return fmt.Errorf("failed to remove flags for UID %d: %w", uid, err)
	}

	return nil
}

// Append uploads a message to a mailbox
// Returns the UID of the appended message (if server supports UIDPLUS)
func (c *Client) Append(mailbox string, flags []string, date time.Time, message []byte) (uint32, error) {
	if c.conn == nil {
		return 0, fmt.Errorf("not connected")
	}

	// Create a reader for the message
	literal := bytes.NewReader(message)

	// Append the message
	if err := c.conn.Append(mailbox, flags, date, literal); err != nil {
		return 0, fmt.Errorf("failed to append message to %s: %w", mailbox, err)
	}

	// Try to get the UID of the appended message
	// We need to search for it since go-imap doesn't return APPENDUID directly
	// Select the mailbox first
	_, err := c.conn.Select(mailbox, false)
	if err != nil {
		return 0, nil // Append succeeded but couldn't get UID
	}

	// Search for messages with \Recent flag (just appended)
	// This is a best-effort approach - may not always work
	criteria := imap.NewSearchCriteria()
	criteria.WithFlags = []string{imap.RecentFlag}
	uids, err := c.conn.UidSearch(criteria)
	if err != nil || len(uids) == 0 {
		return 0, nil // Append succeeded but couldn't determine UID
	}

	// Return the highest UID (most likely our message)
	var maxUID uint32
	for _, uid := range uids {
		if uid > maxUID {
			maxUID = uid
		}
	}

	return maxUID, nil
}

// Delete marks a message as deleted and expunges it
func (c *Client) Delete(uid uint32) error {
	if c.conn == nil {
		return fmt.Errorf("not connected")
	}

	seqSet := new(imap.SeqSet)
	seqSet.AddNum(uid)

	// Add \Deleted flag
	item := imap.FormatFlagsOp(imap.AddFlags, true)
	ifaceFlags := []interface{}{imap.DeletedFlag}

	messages := make(chan *imap.Message, 1)
	done := make(chan error, 1)

	go func() {
		done <- c.conn.UidStore(seqSet, item, ifaceFlags, messages)
	}()

	// Drain messages
	for range messages {
	}

	if err := <-done; err != nil {
		return fmt.Errorf("failed to mark message %d as deleted: %w", uid, err)
	}

	// Expunge to permanently remove
	if err := c.conn.Expunge(nil); err != nil {
		return fmt.Errorf("failed to expunge message %d: %w", uid, err)
	}

	return nil
}

// FindDraftsMailbox finds the Drafts mailbox using SPECIAL-USE attributes
// Falls back to common names if SPECIAL-USE is not available
func (c *Client) FindDraftsMailbox() (string, error) {
	if c.conn == nil {
		return "", fmt.Errorf("not connected")
	}

	mailboxes, err := c.ListMailboxes()
	if err != nil {
		return "", err
	}

	// First pass: look for \Drafts SPECIAL-USE attribute
	for _, mbox := range mailboxes {
		for _, attr := range mbox.Attributes {
			if strings.EqualFold(attr, "\\Drafts") {
				return mbox.Name, nil
			}
		}
	}

	// Second pass: look for common draft folder names
	commonNames := []string{
		"Drafts",
		"Draft",
		"INBOX.Drafts",
		"INBOX.Draft",
		"[Gmail]/Drafts",
		"Entwürfe",   // German
		"Brouillons", // French
	}

	for _, name := range commonNames {
		for _, mbox := range mailboxes {
			if strings.EqualFold(mbox.Name, name) {
				return mbox.Name, nil
			}
		}
	}

	return "", fmt.Errorf("drafts mailbox not found")
}

// SearchByMessageID searches for a message by its Message-ID header
// Returns the UID if found, 0 if not found
func (c *Client) SearchByMessageID(messageID string) (uint32, error) {
	if c.conn == nil {
		return 0, fmt.Errorf("not connected")
	}

	// Clean up Message-ID (remove < > if present)
	messageID = strings.Trim(messageID, "<>")

	criteria := imap.NewSearchCriteria()
	criteria.Header.Add("Message-ID", "<"+messageID+">")

	uids, err := c.conn.UidSearch(criteria)
	if err != nil {
		return 0, fmt.Errorf("failed to search for Message-ID: %w", err)
	}

	if len(uids) == 0 {
		return 0, nil // Not found
	}

	return uids[0], nil
}

// Close closes the IMAP connection
func (c *Client) Close() error {
	if c.conn == nil {
		return nil
	}

	// Logout gracefully
	if err := c.conn.Logout(); err != nil {
		// Still try to close the connection
		c.conn.Close()
		return err
	}

	return c.conn.Close()
}

// Account returns the account config
func (c *Client) Account() *config.AccountConfig {
	return c.account
}

// XOAuth2Client implements go-sasl Client interface for XOAUTH2
type XOAuth2Client struct {
	username string
	token    string
}

// NewXOAuth2Client creates a new XOAUTH2 SASL client
func NewXOAuth2Client(username, token string) *XOAuth2Client {
	return &XOAuth2Client{
		username: username,
		token:    token,
	}
}

// Start begins SASL authentication
func (c *XOAuth2Client) Start() (mech string, ir []byte, err error) {
	mech = "XOAUTH2"
	// XOAUTH2 format: user=<email>\x01auth=Bearer <token>\x01\x01
	ir = []byte(fmt.Sprintf("user=%s\x01auth=Bearer %s\x01\x01", c.username, c.token))
	return
}

// Next handles server challenges
func (c *XOAuth2Client) Next(challenge []byte) ([]byte, error) {
	// Server sent an error - return empty response to get error details
	return nil, fmt.Errorf("XOAUTH2 error: %s", string(challenge))
}
