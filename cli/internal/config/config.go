package config

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/BurntSushi/toml"
)

// Load loads configuration from the given path
// If path is empty, uses default path resolution
func Load(path string) (*Config, error) {
	if path == "" {
		path = DefaultPath()
	}

	path = ExpandPath(path)

	var cfg Config
	if _, err := toml.DecodeFile(path, &cfg); err != nil {
		return nil, fmt.Errorf("failed to load config: %w", err)
	}

	// Validate aliases
	if err := cfg.ValidateAliases(); err != nil {
		return nil, fmt.Errorf("config validation failed: %w", err)
	}

	return &cfg, nil
}

// DefaultPath returns the default config path
// Respects XDG_CONFIG_HOME, falls back to ~/.config/durian/config.toml
func DefaultPath() string {
	if xdg := os.Getenv("XDG_CONFIG_HOME"); xdg != "" {
		return filepath.Join(xdg, "durian", "config.toml")
	}

	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}

	return filepath.Join(home, ".config", "durian", "config.toml")
}

// ExpandPath expands ~ and environment variables in path
func ExpandPath(path string) string {
	if path == "" {
		return path
	}

	// Expand ~
	if strings.HasPrefix(path, "~/") {
		home, err := os.UserHomeDir()
		if err == nil {
			path = filepath.Join(home, path[2:])
		}
	} else if path == "~" {
		home, err := os.UserHomeDir()
		if err == nil {
			path = home
		}
	}

	// Expand environment variables
	path = os.ExpandEnv(path)

	return filepath.Clean(path)
}

// Exists checks if config file exists at path
func Exists(path string) bool {
	if path == "" {
		path = DefaultPath()
	}
	path = ExpandPath(path)

	info, err := os.Stat(path)
	if err != nil {
		return false
	}

	return !info.IsDir()
}

// Default returns an empty default config
func Default() *Config {
	return &Config{
		Settings: SettingsConfig{
			Theme:                "light",
			NotificationsEnabled: true,
			LoadRemoteImages:     true,
		},
		Sync: SyncConfig{
			AutoFetchEnabled:  true,
			AutoFetchInterval: 120,
			FullSyncInterval:  7200,
		},
		Signatures: map[string]string{},
		Accounts:   []AccountConfig{},
	}
}
