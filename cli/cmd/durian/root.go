package main

import (
	"os"

	"github.com/spf13/cobra"
)

// Version is set via -ldflags "-X main.version=..."
var version = "dev"

// Global flags
var (
	cfgFile    string
	jsonOutput bool
)

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
}
