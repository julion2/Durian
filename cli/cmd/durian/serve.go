package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/gorilla/mux"
	"github.com/spf13/cobra"

	"github.com/durian-dev/durian/cli/internal/config"
	"github.com/durian-dev/durian/cli/internal/handler"
	"github.com/durian-dev/durian/cli/internal/notmuch"
)

var serveCmd = &cobra.Command{
	Use:   "serve",
	Short: "Start OpenAPI HTTP server (for GUI integration)",
	Long: `Start the OpenAPI HTTP server that provides a RESTful API for the GUI.
This replaces the old JSON protocol server.`,
	Run: runServe,
}

func init() {
	rootCmd.AddCommand(serveCmd)
}

func runServe(cmd *cobra.Command, args []string) {
	nmClient := notmuch.NewClient("")
	h := handler.New(nmClient)
	eventHub := handler.NewEventHub()

	r := mux.NewRouter()
	r.HandleFunc("/api/v1/search", h.SearchHandler).Methods("GET")
	r.HandleFunc("/api/v1/tags", h.ListTagsHandler).Methods("GET")
	r.HandleFunc("/api/v1/threads/{thread_id}", h.ShowThreadHandler).Methods("GET")
	r.HandleFunc("/api/v1/threads/{thread_id}/tags", h.TagThreadHandler).Methods("POST")
	r.HandleFunc("/api/v1/message/body", h.ShowMessageBodyHandler).Methods("GET")
	r.Handle("/api/v1/events", eventHub).Methods("GET")

	// Start IMAP IDLE watchers if accounts are configured
	watcherCtx, watcherCancel := context.WithCancel(context.Background())
	defer watcherCancel()

	cfg, err := config.Load(cfgFile)
	if err != nil {
		log.Printf("SERVE: warning: could not load config: %v", err)
	} else {
		accounts := cfg.GetAccountsWithIMAP()
		if len(accounts) == 0 {
			log.Printf("SERVE: no IMAP accounts configured, skipping watchers")
		} else {
			watcher := handler.NewWatcherManager(eventHub, nmClient)
			go watcher.Start(watcherCtx, accounts)
			log.Printf("SERVE: started IDLE watchers for %d account(s)", len(accounts))
		}
	}

	server := &http.Server{
		Addr:    ":9723",
		Handler: r,
	}

	// Graceful shutdown
	go func() {
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("could not listen on %s: %v\n", server.Addr, err)
		}
	}()

	fmt.Println("Server is ready to handle requests at", server.Addr)
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit
	fmt.Println("Server is shutting down...")

	// Stop watchers before server shutdown
	watcherCancel()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := server.Shutdown(ctx); err != nil {
		log.Fatalf("Server forced to shutdown: %v", err)
	}

	fmt.Println("Server exiting")
}
