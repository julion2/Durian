package config

// Config represents the complete Durian configuration
type Config struct {
	Settings   SettingsConfig    `toml:"settings"`
	Sync       SyncConfig        `toml:"sync"`
	Contacts   ContactsConfig    `toml:"contacts"`
	Signatures map[string]string `toml:"signatures"`
	Accounts   []AccountConfig   `toml:"accounts"`
}

// SettingsConfig contains GUI-only settings (ignored by CLI)
type SettingsConfig struct {
	Theme                string `toml:"theme"`
	NotificationsEnabled bool   `toml:"notifications_enabled"`
	LoadRemoteImages     bool   `toml:"load_remote_images"`
}

// SyncConfig contains sync settings
type SyncConfig struct {
	AutoFetchEnabled  bool    `toml:"auto_fetch_enabled"`
	AutoFetchInterval float64 `toml:"auto_fetch_interval"` // seconds
	FullSyncInterval  float64 `toml:"full_sync_interval"`  // seconds
}

// ContactsConfig contains contacts database settings
type ContactsConfig struct {
	Enabled bool   `toml:"enabled"` // Enable contacts feature (default: true)
	DBPath  string `toml:"db_path"` // Path to SQLite DB (default: ~/.config/durian/contacts.db)
}

// AccountConfig represents a single email account
type AccountConfig struct {
	Name             string      `toml:"name"`
	DisplayName      string      `toml:"display_name"` // Full name for From header (e.g., "Julian Schenker")
	Email            string      `toml:"email"`
	AuthEmail        string      `toml:"auth_email"` // Delegating user for shared mailbox OAuth (token owner)
	Alias            string      `toml:"alias"`      // Short alias for CLI (e.g., "gmx", "habric")
	Default          bool        `toml:"default"`
	DefaultSignature string      `toml:"default_signature"`
	Notifications    *bool       `toml:"notifications"` // Per-account notification override (nil = use global setting)
	SMTP             SMTPConfig  `toml:"smtp"`
	IMAP             IMAPConfig  `toml:"imap"`
	Auth             AuthConfig  `toml:"auth"`
	OAuth            OAuthConfig `toml:"oauth"`
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
	Host              string `toml:"host"`
	Port              int    `toml:"port"`
	SSL               bool   `toml:"ssl"`
	Auth              string `toml:"auth"`                // "password" or "oauth2"
	MaxAttachmentSize string `toml:"max_attachment_size"` // e.g. "25MB", default 25MB
}

// IMAPConfig contains IMAP server settings
type IMAPConfig struct {
	Host        string   `toml:"host"`
	Port        int      `toml:"port"`
	Auth        string   `toml:"auth"`         // "password" or "oauth2"
	MaxMessages int      `toml:"max_messages"` // Default: 5000, 0 = unlimited
	BatchSize   int      `toml:"batch_size"`   // Default: 5000
	Mailboxes   []string `toml:"mailboxes"`    // Optional: specific mailboxes to sync
}

// AuthConfig contains password-based authentication settings
type AuthConfig struct {
	Username         string `toml:"username"`
	PasswordKeychain string `toml:"password_keychain"`
}

// OAuthConfig contains OAuth2 authentication settings
type OAuthConfig struct {
	Provider     string `toml:"provider"`      // "google", "microsoft"
	ClientID     string `toml:"client_id"`     // Azure App Client ID or Google Client ID
	ClientSecret string `toml:"client_secret"` // Required for Google, optional for Microsoft
	Tenant       string `toml:"tenant"`        // Microsoft tenant (default: "common")
}
