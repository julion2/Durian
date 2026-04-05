package config

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/BurntSushi/toml"
)

// KeymapConfig represents the full keymaps.toml file.
type KeymapConfig struct {
	Keymaps        []KeymapEntry        `toml:"keymaps"`
	GlobalSettings KeymapGlobalSettings `toml:"global_settings"`
}

// KeymapEntry represents a single keymap binding.
type KeymapEntry struct {
	Action        string   `toml:"action"`
	Key           string   `toml:"key"`
	Modifiers     []string `toml:"modifiers"`
	Description   string   `toml:"description"`
	Enabled       bool     `toml:"enabled"`
	Sequence      bool     `toml:"sequence"`
	SupportsCount bool     `toml:"supports_count"`
	Context       string   `toml:"context"`
}

// KeymapGlobalSettings contains global keymap preferences.
type KeymapGlobalSettings struct {
	KeymapsEnabled  bool    `toml:"keymaps_enabled"`
	ShowKeymapHints bool    `toml:"show_keymap_hints"`
	SequenceTimeout float64 `toml:"sequence_timeout"`
}

// LoadKeymaps loads and parses keymaps.toml from the given path.
// If path is empty, uses the default config directory.
// Returns nil (not error) if the file doesn't exist.
func LoadKeymaps(path string) (*KeymapConfig, error) {
	if path == "" {
		path = filepath.Join(filepath.Dir(DefaultPath()), "keymaps.toml")
	}

	if _, err := os.Stat(path); os.IsNotExist(err) {
		return nil, nil
	}

	var cfg KeymapConfig
	if _, err := toml.DecodeFile(path, &cfg); err != nil {
		return nil, fmt.Errorf("failed to load keymaps: %w", err)
	}

	return &cfg, nil
}
