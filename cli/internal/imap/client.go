package imap

import (
	"crypto/tls"
	"fmt"
	"net"
	"os/exec"
	"strings"
	"time"

	"github.com/emersion/go-imap"
	"github.com/emersion/go-imap/client"
	"github.com/emersion/go-sasl"

	"github.com/durian-dev/durian/cli/internal/config"
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

	password, err := getPasswordFromKeychain(c.account.Auth.PasswordKeychain, username)
	if err != nil {
		return fmt.Errorf("failed to get password: %w", err)
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

	messages := make(chan *imap.Message, len(uids))
	done := make(chan error, 1)

	go func() {
		done <- c.conn.UidFetch(seqSet, items, messages)
	}()

	var result []*imap.Message
	for msg := range messages {
		result = append(result, msg)
	}

	if err := <-done; err != nil {
		return nil, fmt.Errorf("failed to fetch messages: %w", err)
	}

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

// getPasswordFromKeychain retrieves a password from macOS Keychain
func getPasswordFromKeychain(service, account string) (string, error) {
	cmd := exec.Command("security", "find-generic-password", "-s", service, "-a", account, "-w")
	output, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("keychain entry not found: %w", err)
	}
	return strings.TrimSpace(string(output)), nil
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
