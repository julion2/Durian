package config

// Config represents the complete Durian configuration
type Config struct {
	Settings   SettingsConfig    `pkl:"settings" json:"settings"`
	Sync       SyncConfig        `pkl:"sync" json:"sync"`
	Contacts   ContactsConfig    `pkl:"contacts" json:"contacts"`
	Signatures map[string]string `pkl:"signatures" json:"signatures"`
	Accounts   []AccountConfig   `pkl:"accounts" json:"accounts"`
}

// SettingsConfig holds settings that `durian validate` can check before
// the Swift GUI loads the same config file. All other GUI-only fields
// (theme, notifications_enabled, load_remote_images, …) are parsed by
// Swift directly and silently ignored here.
type SettingsConfig struct {
	AccentColor string `pkl:"accent_color" json:"accent_color"` // Hex color, e.g. "#3B82F6"
}

// SyncConfig contains sync settings consumed by the Go CLI.
// The GUI auto-sync interval fields (gui_auto_sync, auto_fetch_interval,
// full_sync_interval) are read by Swift directly and silently ignored here.
type SyncConfig struct {
	// TagSync configures the optional tag sync server for multi-machine setups
	TagSync TagSyncConfig `pkl:"tag_sync" json:"tag_sync"`
}

// TagSyncConfig configures the optional remote tag sync server.
type TagSyncConfig struct {
	URL    string `pkl:"url" json:"url"`     // e.g. "http://nas:8724"
	APIKey string `pkl:"api_key" json:"api_key"` // Shared secret
}

// ContactsConfig contains contacts database settings
type ContactsConfig struct {
	Enabled bool   `pkl:"enabled" json:"enabled"` // Enable contacts feature (default: true)
	DBPath  string `pkl:"db_path" json:"db_path"` // Path to SQLite DB (default: ~/.config/durian/contacts.db)
}

// AccountConfig represents a single email account
type AccountConfig struct {
	Name             string      `pkl:"name" json:"name"`
	DisplayName      string      `pkl:"display_name" json:"display_name"` // Full name for From header (e.g., "Julian Schenker")
	Email            string      `pkl:"email" json:"email"`
	AuthEmail        string      `pkl:"auth_email" json:"auth_email"` // Delegating user for shared mailbox OAuth (token owner)
	Alias            string      `pkl:"alias" json:"alias"`      // Short alias for CLI (e.g., "work", "personal")
	Default          bool        `pkl:"default" json:"default"`
	DefaultSignature string      `pkl:"default_signature" json:"default_signature"`
	Notifications    *bool       `pkl:"notifications" json:"notifications"` // Per-account notification override (nil = use global setting)
	SMTP             SMTPConfig  `pkl:"smtp" json:"smtp"`
	IMAP             IMAPConfig  `pkl:"imap" json:"imap"`
	Auth             AuthConfig  `pkl:"auth" json:"auth"`
	OAuth            OAuthConfig `pkl:"oauth" json:"oauth"`
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
	Host              string `pkl:"host" json:"host"`
	Port              int    `pkl:"port" json:"port"`
	SSL               bool   `pkl:"ssl" json:"ssl"`
	Auth              string `pkl:"auth" json:"auth"`                // "password" or "oauth2"
	MaxAttachmentSize string `pkl:"max_attachment_size" json:"max_attachment_size"` // e.g. "25MB", default 25MB
}

// IMAPConfig contains IMAP server settings
type IMAPConfig struct {
	Host        string   `pkl:"host" json:"host"`
	Port        int      `pkl:"port" json:"port"`
	Auth        string   `pkl:"auth" json:"auth"`         // "password" or "oauth2"
	MaxMessages int      `pkl:"max_messages" json:"max_messages"` // Default: 5000, 0 = unlimited
	BatchSize   int      `pkl:"batch_size" json:"batch_size"`   // Default: 100 (see DefaultIMAPBatchSize)
	Mailboxes   []string `pkl:"mailboxes" json:"mailboxes"`    // Optional: specific mailboxes to sync
}

// AuthConfig contains password-based authentication settings
type AuthConfig struct {
	Username         string `pkl:"username" json:"username"`
	PasswordKeychain string `pkl:"password_keychain" json:"password_keychain"`
}

// OAuthConfig contains OAuth2 authentication settings
type OAuthConfig struct {
	Provider     string `pkl:"provider" json:"provider"`      // "google", "microsoft"
	ClientID     string `pkl:"client_id" json:"client_id"`     // Azure App Client ID or Google Client ID
	ClientSecret string `pkl:"client_secret" json:"client_secret"` // Required for Google, optional for Microsoft
	Tenant       string `pkl:"tenant" json:"tenant"`        // Microsoft tenant (default: "common")
}
