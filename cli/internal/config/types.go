package config

// Config represents the complete Durian configuration
type Config struct {
	Settings   SettingsConfig    `json:"settings"`
	Sync       SyncConfig        `json:"sync"`
	Contacts   ContactsConfig    `json:"contacts"`
	Signatures map[string]string `json:"signatures"`
	Accounts   []AccountConfig   `json:"accounts"`
}

// SettingsConfig holds settings that `durian validate` can check before
// the Swift GUI loads the same config file. All other GUI-only fields
// (theme, notifications_enabled, load_remote_images, …) are parsed by
// Swift directly and silently ignored here.
type SettingsConfig struct {
	AccentColor string `json:"accent_color"` // Hex color, e.g. "#3B82F6"
}

// SyncConfig contains sync settings consumed by the Go CLI.
// The GUI auto-sync interval fields (gui_auto_sync, auto_fetch_interval,
// full_sync_interval) are read by Swift directly and silently ignored here.
type SyncConfig struct {
	// TagSync configures the optional tag sync server for multi-machine setups
	TagSync TagSyncConfig `json:"tag_sync"`
}

// TagSyncConfig configures the optional remote tag sync server.
type TagSyncConfig struct {
	URL    string `json:"url"`     // e.g. "http://nas:8724"
	APIKey string `json:"api_key"` // Shared secret
}

// ContactsConfig contains contacts database settings
type ContactsConfig struct {
	Enabled bool   `json:"enabled"` // Enable contacts feature (default: true)
	DBPath  string `json:"db_path"` // Path to SQLite DB (default: ~/.config/durian/contacts.db)
}

// AccountConfig represents a single email account
type AccountConfig struct {
	Name             string      `json:"name"`
	DisplayName      string      `json:"display_name"` // Full name for From header (e.g., "Julian Schenker")
	Email            string      `json:"email"`
	AuthEmail        string      `json:"auth_email"` // Delegating user for shared mailbox OAuth (token owner)
	Alias            string      `json:"alias"`      // Short alias for CLI (e.g., "work", "personal")
	Default          bool        `json:"default"`
	DefaultSignature string      `json:"default_signature"`
	Notifications    *bool       `json:"notifications"` // Per-account notification override (nil = use global setting)
	SMTP             SMTPConfig  `json:"smtp"`
	IMAP             IMAPConfig  `json:"imap"`
	Auth             AuthConfig  `json:"auth"`
	OAuth            OAuthConfig `json:"oauth"`
}

// GetAuthEmail returns the email used for OAuth token lookup.
// For shared mailboxes, this is the delegating user; otherwise the account email.
func (a *AccountConfig) GetAuthEmail() string {
	if a.AuthEmail != "" {
		return a.AuthEmail
	}
	return a.Email
}

// SMTPConfig contains SMTP server settings
type SMTPConfig struct {
	Host              string `json:"host"`
	Port              int    `json:"port"`
	SSL               bool   `json:"ssl"`
	Auth              string `json:"auth"`                // "password" or "oauth2"
	MaxAttachmentSize string `json:"max_attachment_size"` // e.g. "25MB", default 25MB
}

// IMAPConfig contains IMAP server settings
type IMAPConfig struct {
	Host        string   `json:"host"`
	Port        int      `json:"port"`
	Auth        string   `json:"auth"`         // "password" or "oauth2"
	MaxMessages int      `json:"max_messages"` // Default: 5000, 0 = unlimited
	BatchSize   int      `json:"batch_size"`   // Default: 100 (see DefaultIMAPBatchSize)
	Mailboxes   []string `json:"mailboxes"`    // Optional: specific mailboxes to sync
}

// AuthConfig contains password-based authentication settings
type AuthConfig struct {
	Username         string `json:"username"`
	PasswordKeychain string `json:"password_keychain"`
}

// OAuthConfig contains OAuth2 authentication settings
type OAuthConfig struct {
	Provider     string `json:"provider"`      // "google", "microsoft"
	ClientID     string `json:"client_id"`     // Azure App Client ID or Google Client ID
	ClientSecret string `json:"client_secret"` // Required for Google, optional for Microsoft
	Tenant       string `json:"tenant"`        // Microsoft tenant (default: "common")
}
