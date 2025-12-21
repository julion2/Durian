package main

import (
	"fmt"
	"os"

	"github.com/durian-dev/durian/cli/internal/config"
	"github.com/durian-dev/durian/cli/internal/debug"
	"github.com/spf13/cobra"
)

// Version is set via -ldflags "-X main.version=..."
var version = "dev"

// Global flags
var (
	cfgFile    string
	jsonOutput bool
	debugMode  bool
)

// Global config (loaded at startup)
var cfg *config.Config

// rootCmd represents the base command when called without any subcommands
var rootCmd = &cobra.Command{
	Use:     "durian",
	Short:   "Durian Mail CLI - A notmuch-based email client",
	Long:    `Durian is a fast, terminal-based email client that uses notmuch for indexing and searching.`,
	Version: version,
	// Show help when called without subcommands
	Run: func(cmd *cobra.Command, args []string) {
		cmd.Help()
	},
}

// Execute runs the root command
func Execute() {
	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}

func init() {
	// Global flags available to all commands
	rootCmd.PersistentFlags().StringVarP(&cfgFile, "config", "c", "", "config file (default: ~/.config/durian/config.toml)")
	rootCmd.PersistentFlags().BoolVar(&jsonOutput, "json", false, "output as JSON")
	rootCmd.PersistentFlags().BoolVar(&debugMode, "debug", false, "enable debug logging")

	// Load config before command execution
	cobra.OnInitialize(initConfig, initDebug)
}

// initConfig loads configuration from file
func initConfig() {
	var err error

	// Try to load config from specified path or default
	if config.Exists(cfgFile) {
		cfg, err = config.Load(cfgFile)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Warning: failed to load config: %v\n", err)
			cfg = config.Default()
		}
	} else {
		// No config file found - use defaults
		if cfgFile != "" {
			// User specified a path but file doesn't exist
			fmt.Fprintf(os.Stderr, "Warning: config file not found: %s\n", cfgFile)
		}
		// Silently use defaults if no custom path specified
		// (most users won't have config initially)
		cfg = config.Default()
	}
}

// GetConfig returns the loaded configuration
// This is useful for subcommands that need access to config
func GetConfig() *config.Config {
	return cfg
}

// initDebug sets up debug mode based on the --debug flag
func initDebug() {
	debug.Enabled = debugMode
}
