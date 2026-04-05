package config

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/BurntSushi/toml"
)

// RulesConfig holds all user-defined filter rules
type RulesConfig struct {
	Rules []RuleConfig `toml:"rules"`
}

// RuleConfig defines a single filter rule applied at sync time
type RuleConfig struct {
	Name        string   `toml:"name"`
	Match       string   `toml:"match"`
	AddTags     []string `toml:"add_tags"`
	RemoveTags  []string `toml:"remove_tags"`
	Accounts    []string `toml:"accounts"`     // If set, only apply to these accounts (by alias)
	Exec        string   `toml:"exec"`         // Optional: external command to run (stdin=email JSON, stdout=tag ops JSON)
	ExecTimeout int      `toml:"exec_timeout"` // Timeout in seconds (default: 10)
}

// LoadRules loads filter rules from the given path.
// Returns an empty slice if the file doesn't exist.
func LoadRules(path string) ([]RuleConfig, error) {
	if path == "" {
		path = RulesPath()
	}
	path = ExpandPath(path)

	if _, err := os.Stat(path); os.IsNotExist(err) {
		return nil, nil
	}

	var cfg RulesConfig
	if _, err := toml.DecodeFile(path, &cfg); err != nil {
		return nil, fmt.Errorf("failed to load rules: %w", err)
	}

	return cfg.Rules, nil
}

// RulesPath returns the default rules config path
func RulesPath() string {
	return filepath.Join(filepath.Dir(DefaultPath()), "rules.toml")
}
