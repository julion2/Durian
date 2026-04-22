package config

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// ProfileConfig represents a single profile entry.
type ProfileConfig struct {
	Name     string         `json:"name"`
	Accounts []string       `json:"accounts"`
	Default  bool           `json:"default"`
	Color    string         `json:"color"`
	Folders  []FolderConfig `json:"folders"`
}

// FolderConfig represents a folder entry within a profile.
type FolderConfig struct {
	Name  string `json:"name"`
	Icon  string `json:"icon"`
	Query string `json:"query"`
}

type profilesFile struct {
	Profiles []ProfileConfig `json:"profiles"`
}

// LoadProfiles loads and parses profiles.pkl from the given path.
// If path is empty, uses the default config directory.
// Returns nil (not error) if the file doesn't exist.
func LoadProfiles(path string) ([]ProfileConfig, error) {
	if path == "" {
		path = filepath.Join(filepath.Dir(DefaultPath()), "profiles.pkl")
	}

	if _, err := os.Stat(path); os.IsNotExist(err) {
		return nil, nil
	}

	data, err := evalConfigFile(path)
	if err != nil {
		return nil, fmt.Errorf("failed to load profiles: %w", err)
	}

	var cfg profilesFile
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("failed to parse profiles: %w", err)
	}

	return cfg.Profiles, nil
}
