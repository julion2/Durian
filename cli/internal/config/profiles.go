package config

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/BurntSushi/toml"
)

// ProfileConfig represents a single profile entry in profiles.toml.
type ProfileConfig struct {
	Name     string         `toml:"name"`
	Accounts []string       `toml:"accounts"`
	Default  bool           `toml:"default"`
	Color    string         `toml:"color"`
	Folders  []FolderConfig `toml:"folders"`
}

// FolderConfig represents a folder entry within a profile.
type FolderConfig struct {
	Name  string `toml:"name"`
	Icon  string `toml:"icon"`
	Query string `toml:"query"`
}

type profilesFile struct {
	Profile []ProfileConfig `toml:"profile"`
}

// LoadProfiles loads and parses profiles.toml from the given path.
// If path is empty, uses the default config directory.
// Returns nil (not error) if the file doesn't exist.
func LoadProfiles(path string) ([]ProfileConfig, error) {
	if path == "" {
		path = filepath.Join(filepath.Dir(DefaultPath()), "profiles.toml")
	}

	if _, err := os.Stat(path); os.IsNotExist(err) {
		return nil, nil
	}

	var cfg profilesFile
	if _, err := toml.DecodeFile(path, &cfg); err != nil {
		return nil, fmt.Errorf("failed to load profiles: %w", err)
	}

	return cfg.Profile, nil
}
