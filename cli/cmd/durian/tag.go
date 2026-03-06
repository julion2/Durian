package main

import (
	"fmt"
	"os"
	"strings"

	"github.com/durian-dev/durian/cli/internal/notmuch"
	"github.com/durian-dev/durian/cli/internal/handler"
	"github.com/spf13/cobra"
)

var tagCmd = &cobra.Command{
	Use:   "tag <query> <tags...>",
	Short: "Modify tags on emails",
	Long: `Add or remove tags from emails matching the query.

Tags must be prefixed with + (add) or - (remove).
Multiple tags can be specified.`,
	Example: `  durian tag "thread:00000000000022ca" +read
  durian tag "thread:00000000000022ca" +read -unread
  durian tag "tag:inbox" +archived -inbox
  durian tag "from:alice@example.com" +important`,
	Args: cobra.MinimumNArgs(2),
	RunE: runTag,
}

func init() {
	tagCmd.Flags().SetInterspersed(false)
	rootCmd.AddCommand(tagCmd)
}

func runTag(cmd *cobra.Command, args []string) error {
	query := args[0]
	tags := args[1:]

	// Validate tags
	for _, tag := range tags {
		if !strings.HasPrefix(tag, "+") && !strings.HasPrefix(tag, "-") {
			fmt.Fprintf(os.Stderr, "Error: invalid tag format: %q (must start with + or -)\n", tag)
			os.Exit(2)
		}
	}

	nmClient := notmuch.NewClient("")
	h := handler.New(nmClient, nil)

	// Join tags back to string for handler (current interface expects string)
	tagsStr := strings.Join(tags, " ")
	resp := h.Tag(query, tagsStr)

	if !resp.OK {
		fmt.Fprintf(os.Stderr, "Error: %s\n", resp.Error)
		os.Exit(1)
	}

	if !jsonOutput {
		fmt.Println("Tags applied successfully")
	}

	return nil
}
