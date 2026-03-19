package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/gorilla/mux"
	"github.com/spf13/cobra"

	"github.com/durian-dev/durian/cli/internal/config"
	"github.com/durian-dev/durian/cli/internal/contacts"
	"github.com/durian-dev/durian/cli/internal/handler"
	"github.com/durian-dev/durian/cli/internal/store"
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
	// Override default logger: write to serve.log (truncated on each start)
	level := slog.LevelInfo
	if debugMode {
		level = slog.LevelDebug
	}
	logPath := filepath.Join(filepath.Dir(config.DefaultPath()), "serve.log")
	if f, err := os.Create(logPath); err == nil {
		defer f.Close()
		slog.SetDefault(slog.New(slog.NewTextHandler(f, &slog.HandlerOptions{Level: level})))
	}

	// Open contacts database (non-fatal if missing)
	var contactsDB *contacts.DB
	contactsDBPath := contacts.DefaultDBPath()
	if cdb, err := contacts.Open(contactsDBPath); err != nil {
		slog.Warn("Could not open contacts database", "module", "SERVE", "path", contactsDBPath, "err", err)
	} else {
		contactsDB = cdb
		defer contactsDB.Close()
		slog.Info("Opened contacts database", "module", "SERVE", "path", contactsDBPath)
	}

	// Open email store (required for reads)
	emailDB, err := openEmailDB()
	if err != nil {
		slog.Error("Email store required but unavailable", "module", "SERVE", "err", err)
		fmt.Fprintln(os.Stderr, "Error: email store unavailable:", err)
		os.Exit(1)
	}
	defer emailDB.Close()
	slog.Info("Opened email store", "module", "SERVE", "path", store.DefaultDBPath())

	h := handler.New(emailDB, contactsDB)
	eventHub := handler.NewEventHub()

	r := mux.NewRouter()
	r.HandleFunc("/api/v1/search", h.SearchHandler).Methods("GET")
	r.HandleFunc("/api/v1/search/count", h.SearchCountHandler).Methods("GET")
	r.HandleFunc("/api/v1/tags", h.ListTagsHandler).Methods("GET")
	r.HandleFunc("/api/v1/threads/{thread_id}", h.ShowThreadHandler).Methods("GET")
	r.HandleFunc("/api/v1/threads/{thread_id}/tags", h.TagThreadHandler).Methods("POST")
	r.HandleFunc("/api/v1/message/body", h.ShowMessageBodyHandler).Methods("GET")
	r.HandleFunc("/api/v1/messages/{message_id}/attachments/{part_id}", h.DownloadAttachmentHandler).Methods("GET")
	r.HandleFunc("/api/v1/contacts/search", h.SearchContactsHandler).Methods("GET")
	r.HandleFunc("/api/v1/contacts/usage", h.IncrementContactUsageHandler).Methods("POST")
	r.HandleFunc("/api/v1/contacts", h.ListContactsHandler).Methods("GET")
	r.Handle("/api/v1/events", eventHub).Methods("GET")

	// Outbox routes
	r.HandleFunc("/api/v1/outbox/send", h.EnqueueOutboxHandler).Methods("POST")
	r.HandleFunc("/api/v1/outbox", h.ListOutboxHandler).Methods("GET")
	r.HandleFunc("/api/v1/outbox/{id}", h.DeleteOutboxHandler).Methods("DELETE")

	// Start IMAP IDLE watchers if accounts are configured
	watcherCtx, watcherCancel := context.WithCancel(context.Background())
	defer watcherCancel()

	// Load filter rules (non-fatal if missing)
	rules, rulesErr := config.LoadRules("")
	if rulesErr != nil {
		slog.Warn("Could not load filter rules", "module", "SERVE", "err", rulesErr)
	} else if len(rules) > 0 {
		slog.Info("Loaded filter rules", "module", "SERVE", "count", len(rules))
	}

	cfg, err := config.Load(cfgFile)
	if err != nil {
		slog.Warn("Could not load config", "module", "SERVE", "err", err)
	} else {
		h.SetConfig(cfg)

		accounts := cfg.GetAccountsWithIMAP()
		if len(accounts) == 0 {
			slog.Info("No IMAP accounts configured, skipping watchers", "module", "SERVE")
		} else {
			watcher := handler.NewWatcherManager(eventHub, emailDB, rules)
			h.SetFetcher(watcher)
			h.SetSyncTrigger(watcher)
			go watcher.Start(watcherCtx, accounts)
			slog.Info("Started IDLE watchers", "module", "SERVE", "accounts", len(accounts))
		}

		// Start outbox background worker
		outboxWorker := handler.NewOutboxWorker(emailDB, cfg, eventHub)
		go outboxWorker.Start(watcherCtx)
	}

	server := &http.Server{
		Addr:    ":9723",
		Handler: r,
	}

	// Graceful shutdown
	go func() {
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			slog.Error("Could not listen", "module", "SERVE", "addr", server.Addr, "err", err)
			os.Exit(1)
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
		slog.Error("Server forced to shutdown", "module", "SERVE", "err", err)
		os.Exit(1)
	}

	fmt.Println("Server exiting")
}
