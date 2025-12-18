package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/durian-dev/durian/cli/internal/backend/notmuch"
	"github.com/durian-dev/durian/cli/internal/handler"
	"github.com/durian-dev/durian/cli/internal/mail"
	"github.com/spf13/cobra"
)

var showHTML bool

var showCmd = &cobra.Command{
	Use:   "show <thread-id>",
	Short: "Display email content",
	Long: `Display the content of an email by its thread ID.

By default, the plain text body is shown. Use --html to show the HTML body instead.`,
	Example: `  durian show 00000000000022ca
  durian show 00000000000022ca --html
  durian show 00000000000022ca --json`,
	Args: cobra.ExactArgs(1),
	RunE: runShow,
}

func init() {
	showCmd.Flags().BoolVar(&showHTML, "html", false, "show HTML body instead of plain text")
	rootCmd.AddCommand(showCmd)
}

func runShow(cmd *cobra.Command, args []string) error {
	threadID := args[0]

	nmClient := notmuch.NewExecClient()
	h := handler.New(nmClient)

	resp := h.ShowByThread(threadID)

	if !resp.OK {
		fmt.Fprintf(os.Stderr, "Error: %s\n", resp.Error)
		os.Exit(1)
	}

	if resp.Mail == nil {
		fmt.Fprintln(os.Stderr, "Error: no mail content returned")
		os.Exit(1)
	}

	if jsonOutput {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		return enc.Encode(resp.Mail)
	}

	return outputShowFormatted(resp.Mail)
}

func outputShowFormatted(m *mail.MailContent) error {
	fmt.Printf("From:    %s\n", m.From)
	fmt.Printf("To:      %s\n", m.To)
	fmt.Printf("Subject: %s\n", m.Subject)
	fmt.Printf("Date:    %s\n", m.Date)

	if len(m.Attachments) > 0 {
		fmt.Printf("Attachments: %s\n", strings.Join(m.Attachments, ", "))
	}

	fmt.Println()

	if showHTML && m.HTML != "" {
		fmt.Println(m.HTML)
	} else {
		fmt.Println(m.Body)
	}

	return nil
}
