package config

// Config represents the complete Durian configuration
type Config struct {
	Settings   SettingsConfig    `toml:"settings"`
	Sync       SyncConfig        `toml:"sync"`
	Notmuch    NotmuchConfig     `toml:"notmuch"`
	Signatures map[string]string `toml:"signatures"`
	Accounts   []AccountConfig   `toml:"accounts"`
}

// SettingsConfig contains GUI-only settings (ignored by CLI)
type SettingsConfig struct {
	Theme                string `toml:"theme"`
	NotificationsEnabled bool   `toml:"notifications_enabled"`
	LoadRemoteImages     bool   `toml:"load_remote_images"`
}

// SyncConfig contains mbsync/sync settings
type SyncConfig struct {
	AutoFetchEnabled  bool     `toml:"auto_fetch_enabled"`
	AutoFetchInterval float64  `toml:"auto_fetch_interval"` // seconds
	FullSyncInterval  float64  `toml:"full_sync_interval"`  // seconds
	MbsyncChannels    []string `toml:"mbsync_channels"`
}

// NotmuchConfig contains notmuch-specific settings
type NotmuchConfig struct {
	DatabasePath string `toml:"database_path"`
}

// AccountConfig represents a single email account
type AccountConfig struct {
	Name             string      `toml:"name"`
	Email            string      `toml:"email"`
	Default          bool        `toml:"default"`
	DefaultSignature string      `toml:"default_signature"`
	SMTP             SMTPConfig  `toml:"smtp"`
	Auth             AuthConfig  `toml:"auth"`
	OAuth            OAuthConfig `toml:"oauth"`
}

// SMTPConfig contains SMTP server settings
type SMTPConfig struct {
	Host              string `toml:"host"`
	Port              int    `toml:"port"`
	SSL               bool   `toml:"ssl"`
	Auth              string `toml:"auth"`                // "password" or "oauth2"
	MaxAttachmentSize string `toml:"max_attachment_size"` // e.g. "25MB", default 25MB
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
