package main

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

var sendCmd = &cobra.Command{
	Use:   "send",
	Short: "Send an email (not yet implemented)",
	Long: `Send an email via SMTP.

This feature is not yet implemented. See the GitHub issue for progress:
https://github.com/julion2/Durian/issues/27

Planned features:
  - Interactive mode (prompt for To, Subject, Body)
  - Flags for --to, --cc, --bcc, --subject, --body
  - Attachment support with --attach
  - OAuth2 authentication for Gmail and Microsoft 365`,
	Run: runSend,
}

func init() {
	// Placeholder flags for future implementation
	sendCmd.Flags().StringSlice("to", nil, "recipient email addresses")
	sendCmd.Flags().StringSlice("cc", nil, "CC recipients")
	sendCmd.Flags().StringSlice("bcc", nil, "BCC recipients")
	sendCmd.Flags().String("subject", "", "email subject")
	sendCmd.Flags().String("body", "", "email body")
	sendCmd.Flags().String("body-file", "", "read body from file")
	sendCmd.Flags().StringSlice("attach", nil, "attach files")

	rootCmd.AddCommand(sendCmd)
}

func runSend(cmd *cobra.Command, args []string) {
	fmt.Fprintln(os.Stderr, "Error: send command not yet implemented")
	fmt.Fprintln(os.Stderr, "")
	fmt.Fprintln(os.Stderr, "Track progress: https://github.com/julion2/Durian/issues/27")
	os.Exit(1)
}
