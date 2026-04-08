package handler

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"
	"unicode"

	"github.com/gorilla/mux"
)

// writeJSON encodes response as JSON, logging any encoding errors
func writeJSON(w http.ResponseWriter, response any) {
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(response); err != nil {
		slog.Error("Failed to encode JSON response", "err", err)
	}
}

func (h *Handler) SearchHandler(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query().Get("query")
	if query == "" {
		http.Error(w, "Missing required 'query' parameter", http.StatusBadRequest)
		return
	}
	if len(query) > 1024 {
		http.Error(w, "Query too long (max 1024 characters)", http.StatusBadRequest)
		return
	}
	limitStr := r.URL.Query().Get("limit")
	var limit int
	if limitStr != "" {
		var err error
		limit, err = strconv.Atoi(limitStr)
		if err != nil {
			http.Error(w, "Invalid limit parameter", http.StatusBadRequest)
			return
		}
	}

	var enrichLimit int
	if enrichStr := r.URL.Query().Get("enrich"); enrichStr != "" {
		var err error
		enrichLimit, err = strconv.Atoi(enrichStr)
		if err != nil {
			http.Error(w, "Invalid enrich parameter", http.StatusBadRequest)
			return
		}
	}

	response := h.Search(query, limit, enrichLimit)
	writeJSON(w, response)
}

// SearchCountHandler handles GET /api/v1/search/count?query=...
// Returns {"count": N} for the number of matching threads.
func (h *Handler) SearchCountHandler(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query().Get("query")
	if query == "" {
		http.Error(w, "Missing required 'query' parameter", http.StatusBadRequest)
		return
	}

	count, err := h.store.SearchCount(query)
	if err != nil {
		slog.Error("Search count failed", "module", "HANDLER", "query", query, "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	writeJSON(w, map[string]int{"count": count})
}

func (h *Handler) ShowThreadHandler(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	threadID := vars["thread_id"]
	response := h.ShowThread(threadID)
	writeJSON(w, response)
}

func (h *Handler) ListTagsHandler(w http.ResponseWriter, r *http.Request) {
	account := r.URL.Query().Get("account")
	if account != "" {
		response := h.ListTagsForAccounts(strings.Split(account, ","))
		writeJSON(w, response)
	} else {
		response := h.ListTags()
		writeJSON(w, response)
	}
}

func (h *Handler) ShowMessageBodyHandler(w http.ResponseWriter, r *http.Request) {
	messageID := r.URL.Query().Get("id")
	if messageID == "" {
		http.Error(w, "Missing required 'id' parameter", http.StatusBadRequest)
		return
	}
	response := h.ShowMessageBody(messageID)
	writeJSON(w, response)
}

func (h *Handler) DownloadAttachmentHandler(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	messageID := vars["message_id"]
	partIDStr := vars["part_id"]

	partID, err := strconv.Atoi(partIDStr)
	if err != nil {
		http.Error(w, "Invalid part_id parameter", http.StatusBadRequest)
		return
	}

	if err := h.DownloadAttachment(messageID, partID, w); err != nil {
		slog.Warn("Attachment download failed", "module", "HANDLER", "message_id", messageID, "part_id", partID, "err", err)
		http.Error(w, err.Error(), http.StatusNotFound)
	}
}

// sanitizeFilename removes path separators and other dangerous characters from
// an attachment filename to prevent directory traversal in Content-Disposition.
func sanitizeFilename(name string) string {
	name = filepath.Base(name)
	name = strings.Map(func(r rune) rune {
		if r == 0 || unicode.IsControl(r) {
			return -1
		}
		return r
	}, name)
	name = strings.ReplaceAll(name, `"`, "")
	if name == "" || name == "." {
		return "attachment"
	}
	return name
}

func (h *Handler) TagThreadHandler(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	threadID := vars["thread_id"]

	var tagRequest struct {
		Tags string `json:"tags"`
	}
	if err := json.NewDecoder(r.Body).Decode(&tagRequest); err != nil {
		http.Error(w, "Invalid request body", http.StatusBadRequest)
		return
	}

	response := h.Tag("thread:"+threadID, tagRequest.Tags)
	writeJSON(w, response)
}
