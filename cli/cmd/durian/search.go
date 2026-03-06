package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"text/tabwriter"

	"github.com/durian-dev/durian/cli/internal/notmuch"
	"github.com/durian-dev/durian/cli/internal/handler"
	"github.com/durian-dev/durian/cli/internal/protocol"
	"github.com/spf13/cobra"
)

var searchLimit int

var searchCmd = &cobra.Command{
	Use:   "search <query>",
	Short: "Search emails using notmuch query syntax",
	Long: `Search for emails using notmuch query syntax.

The query follows notmuch search syntax. Common examples:
  tag:inbox          - all emails with inbox tag
  tag:unread         - all unread emails
  from:alice@ex.com  - emails from Alice
  subject:meeting    - emails with "meeting" in subject
  date:yesterday..   - emails from yesterday onwards`,
	Example: `  durian search "tag:inbox"
  durian search "tag:inbox AND tag:unread"
  durian search "from:alice@example.com" --limit 10
  durian search "tag:unread" --json`,
	Args: cobra.MinimumNArgs(1),
	RunE: runSearch,
}

func init() {
	searchCmd.Flags().IntVarP(&searchLimit, "limit", "l", 50, "maximum number of results")
	rootCmd.AddCommand(searchCmd)
}

func runSearch(cmd *cobra.Command, args []string) error {
	// Join all arguments to allow unquoted queries like: durian search tag:inbox AND date:today
	query := strings.Join(args, " ")

	nmClient := notmuch.NewClient("")
	h := handler.New(nmClient, nil)

	resp := h.Search(query, searchLimit, 0)

	if !resp.OK {
		fmt.Fprintf(os.Stderr, "Error: %s\n", resp.Error)
		os.Exit(1)
	}

	if jsonOutput {
		return outputSearchJSON(resp)
	}

	return outputSearchTable(resp)
}

func outputSearchJSON(resp protocol.Response) error {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(resp.Results)
}

func outputSearchTable(resp protocol.Response) error {
	if len(resp.Results) == 0 {
		fmt.Println("No results found")
		return nil
	}

	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "THREAD\tSUBJECT\tFROM\tDATE\tTAGS")

	for _, mail := range resp.Results {
		subject := truncate(mail.Subject, 45)
		from := truncate(mail.From, 20)
		fmt.Fprintf(w, "%s\t%s\t%s\t%s\t%s\n",
			mail.ThreadID,
			subject,
			from,
			mail.Date,
			mail.Tags,
		)
	}

	return w.Flush()
}

func truncate(s string, maxLen int) string {
	s = strings.ReplaceAll(s, "\n", " ")
	s = strings.ReplaceAll(s, "\t", " ")
	if len(s) <= maxLen {
		return s
	}
	if maxLen <= 3 {
		return s[:maxLen]
	}
	return s[:maxLen-3] + "..."
}
