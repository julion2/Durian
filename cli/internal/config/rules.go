package config

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// RulesConfig holds all user-defined filter rules
type RulesConfig struct {
	Rules []RuleConfig `json:"rules"`
}

// RuleConfig defines a single filter rule applied at sync time
type RuleConfig struct {
	Name        string   `json:"name"`
	Match       string   `json:"match"`
	AddTags     []string `json:"add_tags"`
	RemoveTags  []string `json:"remove_tags"`
	Accounts    []string `json:"accounts"`     // If set, only apply to these accounts (by alias)
	Exec        string   `json:"exec"`          // Optional: external command to run (stdin=email JSON, stdout=tag ops JSON)
	ExecTimeout int      `json:"exec_timeout"`  // Timeout in seconds (default: 10)
	AllowedTags []string `json:"allowed_tags"`  // Optional: restrict exec output to these tags
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

	data, err := evalConfigFile(path)
	if err != nil {
		return nil, fmt.Errorf("failed to load rules: %w", err)
	}

	var cfg RulesConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("failed to parse rules: %w", err)
	}

	return cfg.Rules, nil
}

// RulesPath returns the default rules config path
func RulesPath() string {
	return filepath.Join(filepath.Dir(DefaultPath()), "rules.pkl")
}
