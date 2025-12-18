package main

import (
	"os"

	"github.com/durian-dev/durian/cli/internal/backend/notmuch"
	"github.com/durian-dev/durian/cli/internal/handler"
	"github.com/durian-dev/durian/cli/internal/protocol"
	"github.com/spf13/cobra"
)

var serveCmd = &cobra.Command{
	Use:   "serve",
	Short: "Start JSON protocol server (for GUI integration)",
	Long: `Start the JSON protocol server that reads commands from stdin
and writes responses to stdout. This is used for GUI integration.

The server accepts JSON commands in the format:
  {"cmd": "search", "query": "tag:inbox", "limit": 50}
  {"cmd": "show", "thread": "abc123"}
  {"cmd": "tag", "query": "thread:abc123", "tags": "+read -unread"}`,
	Run: runServe,
}

func init() {
	rootCmd.AddCommand(serveCmd)
}

func runServe(cmd *cobra.Command, args []string) {
	nmClient := notmuch.NewExecClient()
	h := handler.New(nmClient)
	server := protocol.NewServer(h, os.Stdin, os.Stdout)
	server.Run()
}
