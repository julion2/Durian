package config

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// KeymapConfig represents the full keymaps configuration.
type KeymapConfig struct {
	Keymaps        []KeymapEntry        `json:"keymaps"`
	GlobalSettings KeymapGlobalSettings `json:"global_settings"`
}

// KeymapEntry represents a single keymap binding.
type KeymapEntry struct {
	Action        string   `json:"action"`
	Key           string   `json:"key"`
	Modifiers     []string `json:"modifiers"`
	Description   string   `json:"description"`
	Enabled       bool     `json:"enabled"`
	Sequence      bool     `json:"sequence"`
	SupportsCount bool     `json:"supports_count"`
	Context       string   `json:"context"`
}

// KeymapGlobalSettings contains global keymap preferences.
type KeymapGlobalSettings struct {
	KeymapsEnabled  bool    `json:"keymaps_enabled"`
	ShowKeymapHints bool    `json:"show_keymap_hints"`
	SequenceTimeout float64 `json:"sequence_timeout"`
}

// LoadKeymaps loads and parses keymaps.pkl from the given path.
// If path is empty, uses the default config directory.
// Returns nil (not error) if the file doesn't exist.
func LoadKeymaps(path string) (*KeymapConfig, error) {
	if path == "" {
		path = filepath.Join(filepath.Dir(DefaultPath()), "keymaps.pkl")
	}

	if _, err := os.Stat(path); os.IsNotExist(err) {
		return nil, nil
	}

	data, err := evalConfigFile(path)
	if err != nil {
		return nil, fmt.Errorf("failed to load keymaps: %w", err)
	}

	var cfg KeymapConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("failed to parse keymaps: %w", err)
	}

	return &cfg, nil
}
