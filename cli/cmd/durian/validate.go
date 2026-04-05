package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"

	"github.com/durian-dev/durian/cli/internal/config"
	"github.com/durian-dev/durian/cli/internal/imap"
)

var validateCmd = &cobra.Command{
	Use:   "validate [config|rules|profiles|keymaps]",
	Short: "Validate configuration files",
	Long: `Validate Durian configuration files for errors.
Without arguments, validates all files. Pass a name to validate just one.`,
	Example: `  durian validate
  durian validate config
  durian validate rules
  durian validate profiles`,
	Args: cobra.MaximumNArgs(1),
	RunE: runValidate,
}

func init() {
	rootCmd.AddCommand(validateCmd)
}

func runValidate(cmd *cobra.Command, args []string) error {
	target := ""
	if len(args) > 0 {
		target = strings.ToLower(args[0])
		switch target {
		case "config", "rules", "profiles", "keymaps":
		default:
			return fmt.Errorf("unknown target %q (valid: config, rules, profiles, keymaps)", target)
		}
	}

	configDir := filepath.Dir(config.DefaultPath())
	hasErrors := false

	// Always load config first (needed as reference for other validations)
	var loadedCfg *config.Config
	configPath := config.DefaultPath()
	if cfgFile != "" {
		configPath = cfgFile
	}

	if config.Exists(configPath) {
		var err error
		loadedCfg, err = config.Load(configPath)
		if err != nil && (target == "" || target == "config") {
			printError("config.toml", fmt.Sprintf("failed to parse: %v", err))
			hasErrors = true
			loadedCfg = config.Default()
		}
	} else {
		loadedCfg = config.Default()
		if target == "" || target == "config" {
			printSkipped("config.toml", "not found")
		}
	}

	// Validate config.toml
	if target == "" || target == "config" {
		if config.Exists(configPath) {
			errs := config.ValidateConfig(loadedCfg)
			if printResults("config.toml", errs, configSummary(loadedCfg)) {
				hasErrors = true
			}
		}
	}

	// Validate rules.toml
	if target == "" || target == "rules" {
		rulesPath := filepath.Join(configDir, "rules.toml")
		rules, err := config.LoadRules("")
		if err != nil {
			printError("rules.toml", fmt.Sprintf("failed to parse: %v", err))
			hasErrors = true
		} else if rules == nil {
			printSkipped("rules.toml", "not found at "+rulesPath)
		} else {
			errs := config.ValidateRules(rules, loadedCfg, imap.ValidateRuleQuery)
			if printResults("rules.toml", errs, fmt.Sprintf("%d rules", len(rules))) {
				hasErrors = true
			}
		}
	}

	// Validate profiles.toml
	if target == "" || target == "profiles" {
		profiles, err := config.LoadProfiles("")
		if err != nil {
			printError("profiles.toml", fmt.Sprintf("failed to parse: %v", err))
			hasErrors = true
		} else if profiles == nil {
			printSkipped("profiles.toml", "not found (using defaults)")
		} else {
			errs := config.ValidateProfiles(profiles, loadedCfg)
			if printResults("profiles.toml", errs, fmt.Sprintf("%d profiles", len(profiles))) {
				hasErrors = true
			}
		}
	}

	// Validate keymaps.toml
	if target == "" || target == "keymaps" {
		keymaps, err := config.LoadKeymaps("")
		if err != nil {
			printError("keymaps.toml", fmt.Sprintf("failed to parse: %v", err))
			hasErrors = true
		} else if keymaps == nil {
			printSkipped("keymaps.toml", "not found (using defaults)")
		} else {
			errs := config.ValidateKeymaps(keymaps)
			if printResults("keymaps.toml", errs, fmt.Sprintf("%d bindings", len(keymaps.Keymaps))) {
				hasErrors = true
			}
		}
	}

	if hasErrors {
		os.Exit(1)
	}
	return nil
}

func configSummary(cfg *config.Config) string {
	if len(cfg.Accounts) == 0 {
		return "no accounts"
	}
	names := make([]string, 0, len(cfg.Accounts))
	for _, a := range cfg.Accounts {
		names = append(names, a.Name)
	}
	return fmt.Sprintf("%d accounts (%s)", len(cfg.Accounts), strings.Join(names, ", "))
}

// printResults prints validation results and returns true if errors were found.
func printResults(file string, errs []config.ValidationError, summary string) bool {
	errors := 0
	warnings := 0
	for _, e := range errs {
		if e.Severity == "error" {
			errors++
		} else {
			warnings++
		}
	}

	if errors == 0 && warnings == 0 {
		fmt.Printf("  ✓ %s — %s\n", file, summary)
		return false
	}

	if errors > 0 {
		fmt.Printf("  ✗ %s — %s\n", file, summary)
	} else {
		fmt.Printf("  ~ %s — %s\n", file, summary)
	}
	for _, e := range errs {
		if e.Severity == "error" {
			fmt.Printf("    ✗ %s\n", e)
		} else {
			fmt.Printf("    ~ %s\n", e)
		}
	}
	return errors > 0
}

func printError(file, msg string) {
	fmt.Printf("  ✗ %s — %s\n", file, msg)
}

func printSkipped(file, msg string) {
	fmt.Printf("  - %s — %s\n", file, msg)
}
