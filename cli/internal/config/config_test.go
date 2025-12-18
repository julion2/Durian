package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoad(t *testing.T) {
	tests := []struct {
		name        string
		file        string
		wantErr     bool
		errContains string
	}{
		{
			name:    "valid config",
			file:    "testdata/valid_config.toml",
			wantErr: false,
		},
		{
			name:    "minimal config",
			file:    "testdata/minimal_config.toml",
			wantErr: false,
		},
		{
			name:        "invalid syntax",
			file:        "testdata/invalid_syntax.toml",
			wantErr:     true,
			errContains: "failed to load config",
		},
		{
			name:        "nonexistent file",
			file:        "testdata/does_not_exist.toml",
			wantErr:     true,
			errContains: "failed to load config",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg, err := Load(tt.file)
			if tt.wantErr {
				if err == nil {
					t.Errorf("Load() expected error, got nil")
				} else if tt.errContains != "" && !containsString(err.Error(), tt.errContains) {
					t.Errorf("Load() error = %v, want error containing %q", err, tt.errContains)
				}
				return
			}
			if err != nil {
				t.Errorf("Load() unexpected error: %v", err)
				return
			}
			if cfg == nil {
				t.Errorf("Load() returned nil config")
			}
		})
	}
}

func TestLoadValidConfig(t *testing.T) {
	cfg, err := Load("testdata/valid_config.toml")
	if err != nil {
		t.Fatalf("Load() error: %v", err)
	}

	// Settings
	if cfg.Settings.Theme != "dark" {
		t.Errorf("Settings.Theme = %q, want %q", cfg.Settings.Theme, "dark")
	}
	if !cfg.Settings.NotificationsEnabled {
		t.Error("Settings.NotificationsEnabled = false, want true")
	}
	if cfg.Settings.LoadRemoteImages {
		t.Error("Settings.LoadRemoteImages = true, want false")
	}

	// Sync
	if !cfg.Sync.AutoFetchEnabled {
		t.Error("Sync.AutoFetchEnabled = false, want true")
	}
	if cfg.Sync.AutoFetchInterval != 120 {
		t.Errorf("Sync.AutoFetchInterval = %v, want %v", cfg.Sync.AutoFetchInterval, 120)
	}
	if len(cfg.Sync.MbsyncChannels) != 2 {
		t.Errorf("Sync.MbsyncChannels length = %d, want 2", len(cfg.Sync.MbsyncChannels))
	}

	// Notmuch
	if cfg.Notmuch.DatabasePath != "~/.mail" {
		t.Errorf("Notmuch.DatabasePath = %q, want %q", cfg.Notmuch.DatabasePath, "~/.mail")
	}

	// Signatures
	if len(cfg.Signatures) != 2 {
		t.Errorf("Signatures count = %d, want 2", len(cfg.Signatures))
	}
	if cfg.Signatures["personal"] != "Cheers,\nTest User" {
		t.Errorf("Signatures[personal] = %q, want %q", cfg.Signatures["personal"], "Cheers,\nTest User")
	}

	// Accounts
	if len(cfg.Accounts) != 2 {
		t.Errorf("Accounts count = %d, want 2", len(cfg.Accounts))
	}

	// First account (Work)
	work := cfg.Accounts[0]
	if work.Name != "Work" {
		t.Errorf("Accounts[0].Name = %q, want %q", work.Name, "Work")
	}
	if work.Email != "test@work.com" {
		t.Errorf("Accounts[0].Email = %q, want %q", work.Email, "test@work.com")
	}
	if !work.Default {
		t.Error("Accounts[0].Default = false, want true")
	}
	if work.SMTP.Host != "smtp.work.com" {
		t.Errorf("Accounts[0].SMTP.Host = %q, want %q", work.SMTP.Host, "smtp.work.com")
	}
	if work.SMTP.Port != 587 {
		t.Errorf("Accounts[0].SMTP.Port = %d, want %d", work.SMTP.Port, 587)
	}
	if work.SMTP.Auth != "password" {
		t.Errorf("Accounts[0].SMTP.Auth = %q, want %q", work.SMTP.Auth, "password")
	}
	if work.Auth.PasswordKeychain != "work-account" {
		t.Errorf("Accounts[0].Auth.PasswordKeychain = %q, want %q", work.Auth.PasswordKeychain, "work-account")
	}

	// Second account (Personal with OAuth)
	personal := cfg.Accounts[1]
	if personal.SMTP.Auth != "oauth2" {
		t.Errorf("Accounts[1].SMTP.Auth = %q, want %q", personal.SMTP.Auth, "oauth2")
	}
	if personal.OAuth.Provider != "google" {
		t.Errorf("Accounts[1].OAuth.Provider = %q, want %q", personal.OAuth.Provider, "google")
	}
}

func TestDefaultPath(t *testing.T) {
	// Test with XDG_CONFIG_HOME set
	t.Run("with XDG_CONFIG_HOME", func(t *testing.T) {
		oldXDG := os.Getenv("XDG_CONFIG_HOME")
		defer os.Setenv("XDG_CONFIG_HOME", oldXDG)

		os.Setenv("XDG_CONFIG_HOME", "/custom/config")
		path := DefaultPath()
		expected := "/custom/config/durian/config.toml"
		if path != expected {
			t.Errorf("DefaultPath() = %q, want %q", path, expected)
		}
	})

	// Test without XDG_CONFIG_HOME (uses ~/.config)
	t.Run("without XDG_CONFIG_HOME", func(t *testing.T) {
		oldXDG := os.Getenv("XDG_CONFIG_HOME")
		defer os.Setenv("XDG_CONFIG_HOME", oldXDG)

		os.Unsetenv("XDG_CONFIG_HOME")
		path := DefaultPath()

		home, _ := os.UserHomeDir()
		expected := filepath.Join(home, ".config", "durian", "config.toml")
		if path != expected {
			t.Errorf("DefaultPath() = %q, want %q", path, expected)
		}
	})
}

func TestExpandPath(t *testing.T) {
	home, _ := os.UserHomeDir()

	tests := []struct {
		name  string
		input string
		want  string
	}{
		{
			name:  "empty path",
			input: "",
			want:  "",
		},
		{
			name:  "tilde only",
			input: "~",
			want:  home,
		},
		{
			name:  "tilde with path",
			input: "~/.config/durian",
			want:  filepath.Join(home, ".config", "durian"),
		},
		{
			name:  "absolute path",
			input: "/usr/local/etc/durian",
			want:  "/usr/local/etc/durian",
		},
		{
			name:  "relative path",
			input: "config/durian",
			want:  "config/durian",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := ExpandPath(tt.input)
			if got != tt.want {
				t.Errorf("ExpandPath(%q) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}

func TestExpandPathEnvVar(t *testing.T) {
	oldVal := os.Getenv("TEST_DURIAN_VAR")
	defer os.Setenv("TEST_DURIAN_VAR", oldVal)

	os.Setenv("TEST_DURIAN_VAR", "/test/path")

	got := ExpandPath("$TEST_DURIAN_VAR/config.toml")
	want := "/test/path/config.toml"
	if got != want {
		t.Errorf("ExpandPath() = %q, want %q", got, want)
	}
}

func TestExists(t *testing.T) {
	tests := []struct {
		name string
		path string
		want bool
	}{
		{
			name: "existing file",
			path: "testdata/valid_config.toml",
			want: true,
		},
		{
			name: "nonexistent file",
			path: "testdata/nonexistent.toml",
			want: false,
		},
		{
			name: "directory (not a file)",
			path: "testdata",
			want: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := Exists(tt.path)
			if got != tt.want {
				t.Errorf("Exists(%q) = %v, want %v", tt.path, got, tt.want)
			}
		})
	}
}

func TestDefault(t *testing.T) {
	cfg := Default()

	if cfg == nil {
		t.Fatal("Default() returned nil")
	}
	if cfg.Settings.Theme != "light" {
		t.Errorf("Default Settings.Theme = %q, want %q", cfg.Settings.Theme, "light")
	}
	if !cfg.Settings.NotificationsEnabled {
		t.Error("Default Settings.NotificationsEnabled = false, want true")
	}
	if !cfg.Sync.AutoFetchEnabled {
		t.Error("Default Sync.AutoFetchEnabled = false, want true")
	}
	if cfg.Sync.AutoFetchInterval != 120 {
		t.Errorf("Default Sync.AutoFetchInterval = %v, want %v", cfg.Sync.AutoFetchInterval, 120)
	}
	if len(cfg.Accounts) != 0 {
		t.Errorf("Default Accounts length = %d, want 0", len(cfg.Accounts))
	}
}

func TestGetDefaultAccount(t *testing.T) {
	tests := []struct {
		name      string
		cfg       *Config
		wantEmail string
		wantErr   error
	}{
		{
			name: "has default account",
			cfg: &Config{
				Accounts: []AccountConfig{
					{Name: "A", Email: "a@test.com", Default: false},
					{Name: "B", Email: "b@test.com", Default: true},
				},
			},
			wantEmail: "b@test.com",
			wantErr:   nil,
		},
		{
			name: "no default - returns first",
			cfg: &Config{
				Accounts: []AccountConfig{
					{Name: "A", Email: "a@test.com", Default: false},
					{Name: "B", Email: "b@test.com", Default: false},
				},
			},
			wantEmail: "a@test.com",
			wantErr:   nil,
		},
		{
			name: "no accounts",
			cfg: &Config{
				Accounts: []AccountConfig{},
			},
			wantEmail: "",
			wantErr:   ErrNoAccounts,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			acc, err := tt.cfg.GetDefaultAccount()
			if err != tt.wantErr {
				t.Errorf("GetDefaultAccount() error = %v, want %v", err, tt.wantErr)
				return
			}
			if tt.wantErr == nil && acc.Email != tt.wantEmail {
				t.Errorf("GetDefaultAccount().Email = %q, want %q", acc.Email, tt.wantEmail)
			}
		})
	}
}

func TestGetAccountByEmail(t *testing.T) {
	cfg := &Config{
		Accounts: []AccountConfig{
			{Name: "Work", Email: "work@test.com"},
			{Name: "Personal", Email: "personal@test.com"},
		},
	}

	tests := []struct {
		name     string
		email    string
		wantName string
		wantErr  error
	}{
		{
			name:     "found",
			email:    "work@test.com",
			wantName: "Work",
			wantErr:  nil,
		},
		{
			name:     "not found",
			email:    "unknown@test.com",
			wantName: "",
			wantErr:  ErrAccountNotFound,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			acc, err := cfg.GetAccountByEmail(tt.email)
			if err != tt.wantErr {
				t.Errorf("GetAccountByEmail() error = %v, want %v", err, tt.wantErr)
				return
			}
			if tt.wantErr == nil && acc.Name != tt.wantName {
				t.Errorf("GetAccountByEmail().Name = %q, want %q", acc.Name, tt.wantName)
			}
		})
	}
}

func TestGetAccountByName(t *testing.T) {
	cfg := &Config{
		Accounts: []AccountConfig{
			{Name: "Work", Email: "work@test.com"},
			{Name: "Personal", Email: "personal@test.com"},
		},
	}

	tests := []struct {
		name      string
		accName   string
		wantEmail string
		wantErr   error
	}{
		{
			name:      "found",
			accName:   "Work",
			wantEmail: "work@test.com",
			wantErr:   nil,
		},
		{
			name:      "not found",
			accName:   "Unknown",
			wantEmail: "",
			wantErr:   ErrAccountNotFound,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			acc, err := cfg.GetAccountByName(tt.accName)
			if err != tt.wantErr {
				t.Errorf("GetAccountByName() error = %v, want %v", err, tt.wantErr)
				return
			}
			if tt.wantErr == nil && acc.Email != tt.wantEmail {
				t.Errorf("GetAccountByName().Email = %q, want %q", acc.Email, tt.wantEmail)
			}
		})
	}
}

func TestGetAccountByEmailNoAccounts(t *testing.T) {
	cfg := &Config{Accounts: []AccountConfig{}}
	_, err := cfg.GetAccountByEmail("any@test.com")
	if err != ErrNoAccounts {
		t.Errorf("GetAccountByEmail() error = %v, want %v", err, ErrNoAccounts)
	}
}

func TestGetAccountByNameNoAccounts(t *testing.T) {
	cfg := &Config{Accounts: []AccountConfig{}}
	_, err := cfg.GetAccountByName("any")
	if err != ErrNoAccounts {
		t.Errorf("GetAccountByName() error = %v, want %v", err, ErrNoAccounts)
	}
}

func TestGetSignature(t *testing.T) {
	cfg := &Config{
		Signatures: map[string]string{
			"personal": "Cheers",
			"work":     "Best regards",
		},
	}

	tests := []struct {
		name    string
		sigName string
		want    string
		wantErr error
	}{
		{
			name:    "found",
			sigName: "personal",
			want:    "Cheers",
			wantErr: nil,
		},
		{
			name:    "not found",
			sigName: "unknown",
			want:    "",
			wantErr: ErrSignatureNotFound,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := cfg.GetSignature(tt.sigName)
			if err != tt.wantErr {
				t.Errorf("GetSignature() error = %v, want %v", err, tt.wantErr)
				return
			}
			if got != tt.want {
				t.Errorf("GetSignature() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestGetSignatureNilMap(t *testing.T) {
	cfg := &Config{Signatures: nil}
	_, err := cfg.GetSignature("any")
	if err != ErrSignatureNotFound {
		t.Errorf("GetSignature() error = %v, want %v", err, ErrSignatureNotFound)
	}
}

func TestGetDatabasePath(t *testing.T) {
	home, _ := os.UserHomeDir()

	tests := []struct {
		name string
		path string
		want string
	}{
		{
			name: "empty path",
			path: "",
			want: "",
		},
		{
			name: "tilde path",
			path: "~/.mail",
			want: filepath.Join(home, ".mail"),
		},
		{
			name: "absolute path",
			path: "/var/mail",
			want: "/var/mail",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := &Config{Notmuch: NotmuchConfig{DatabasePath: tt.path}}
			got := cfg.GetDatabasePath()
			if got != tt.want {
				t.Errorf("GetDatabasePath() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestHasAccounts(t *testing.T) {
	tests := []struct {
		name     string
		accounts []AccountConfig
		want     bool
	}{
		{
			name:     "no accounts",
			accounts: []AccountConfig{},
			want:     false,
		},
		{
			name:     "has accounts",
			accounts: []AccountConfig{{Name: "Test"}},
			want:     true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := &Config{Accounts: tt.accounts}
			if got := cfg.HasAccounts(); got != tt.want {
				t.Errorf("HasAccounts() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestAccountCount(t *testing.T) {
	tests := []struct {
		name     string
		accounts []AccountConfig
		want     int
	}{
		{
			name:     "empty",
			accounts: []AccountConfig{},
			want:     0,
		},
		{
			name:     "one account",
			accounts: []AccountConfig{{Name: "A"}},
			want:     1,
		},
		{
			name:     "multiple accounts",
			accounts: []AccountConfig{{Name: "A"}, {Name: "B"}, {Name: "C"}},
			want:     3,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := &Config{Accounts: tt.accounts}
			if got := cfg.AccountCount(); got != tt.want {
				t.Errorf("AccountCount() = %d, want %d", got, tt.want)
			}
		})
	}
}

// Helper function
func containsString(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || len(s) > 0 && containsSubstring(s, substr))
}

func containsSubstring(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}
