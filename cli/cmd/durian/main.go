package main

import (
	"os"

	"github.com/durian-dev/durian/cli/internal/backend/notmuch"
	"github.com/durian-dev/durian/cli/internal/handler"
	"github.com/durian-dev/durian/cli/internal/protocol"
)

func main() {
	// Wire dependencies
	nmClient := notmuch.NewExecClient()
	h := handler.New(nmClient)
	server := protocol.NewServer(h, os.Stdin, os.Stdout)

	// Run JSON protocol server
	server.Run()
}
