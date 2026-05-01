package main

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
	"github.com/spf13/cobra/doc"
)

var genManCmd = &cobra.Command{
	Use:    "gen-man <dir>",
	Short:  "Generate man pages for all commands",
	Hidden: true,
	Args:   cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		dir := args[0]
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return fmt.Errorf("create dir: %w", err)
		}
		header := &doc.GenManHeader{
			Title:   "DURIAN",
			Section: "1",
			Source:  "Durian " + version,
			Manual:  "Durian Manual",
		}
		if err := doc.GenManTree(rootCmd, header, dir); err != nil {
			return fmt.Errorf("generate man pages: %w", err)
		}
		return nil
	},
}

func init() {
	rootCmd.AddCommand(genManCmd)
}
