package store

import (
	"fmt"
	"strings"
	"time"
)

// Search finds threads matching a notmuch-style query string.
// Results are grouped by thread and ordered by most recent message date descending.
func (d *DB) Search(query string, limit int) ([]SearchResult, error) {
	if limit <= 0 {
		limit = 50
	}

	where, params, err := parseQuery(query)
	if err != nil {
		return nil, fmt.Errorf("parse query: %w", err)
	}

	q := `
		SELECT
			m.thread_id,
			MAX(m.subject) AS subject,
			GROUP_CONCAT(DISTINCT m.from_addr) AS authors,
			MAX(m.date) AS max_date
		FROM messages m
	`
	if where != "" {
		q += " WHERE " + where
	}
	q += `
		GROUP BY m.thread_id
		ORDER BY max_date DESC
		LIMIT ?
	`
	params = append(params, limit)

	rows, err := d.db.Query(q, params...)
	if err != nil {
		return nil, fmt.Errorf("search: %w", err)
	}

	// Collect results first and close rows before making additional queries.
	// With SetMaxOpenConns(1), nested queries while rows are open would deadlock.
	var results []SearchResult
	for rows.Next() {
		var r SearchResult
		err := rows.Scan(&r.Thread, &r.Subject, &r.Authors, &r.Timestamp)
		if err != nil {
			rows.Close()
			return nil, fmt.Errorf("scan search result: %w", err)
		}
		r.DateRelative = formatDateRelative(r.Timestamp)
		results = append(results, r)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, fmt.Errorf("iterate search results: %w", err)
	}
	rows.Close()

	// Fetch tags for each thread now that the rows cursor is released
	for i := range results {
		tags, err := d.getThreadTags(results[i].Thread)
		if err != nil {
			return nil, fmt.Errorf("get thread tags: %w", err)
		}
		results[i].Tags = tags
	}

	return results, nil
}

// getThreadTags returns distinct tags for all messages in a thread.
func (d *DB) getThreadTags(threadID string) ([]string, error) {
	rows, err := d.db.Query(`
		SELECT DISTINCT t.tag FROM tags t
		JOIN messages m ON m.id = t.message_id
		WHERE m.thread_id = ?
		ORDER BY t.tag`, threadID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var tags []string
	for rows.Next() {
		var tag string
		if err := rows.Scan(&tag); err != nil {
			return nil, err
		}
		tags = append(tags, tag)
	}
	return tags, rows.Err()
}

// token represents a parsed piece of the query string.
type token struct {
	kind  string // "field", "not_field", "bare", "star"
	field string // e.g. "from", "tag", "subject", "date"
	value string
}

// tokenize breaks a query string into structured tokens.
func tokenize(query string) []token {
	query = strings.TrimSpace(query)
	if query == "" || query == "*" {
		return []token{{kind: "star"}}
	}

	// Strip parentheses — the tokenizer uses implicit AND between all clauses
	query = strings.NewReplacer("(", "", ")", "").Replace(query)

	var tokens []token
	parts := strings.Fields(query)
	for i := 0; i < len(parts); i++ {
		p := parts[i]

		// Skip boolean operators (implicit AND between all clauses)
		if strings.EqualFold(p, "AND") || strings.EqualFold(p, "OR") {
			continue
		}

		// Handle NOT prefix
		negate := false
		if strings.EqualFold(p, "NOT") && i+1 < len(parts) {
			negate = true
			i++
			p = parts[i]
		}

		if idx := strings.Index(p, ":"); idx > 0 {
			field := strings.ToLower(p[:idx])
			value := p[idx+1:]
			kind := "field"
			if negate {
				kind = "not_field"
			}
			tokens = append(tokens, token{kind: kind, field: field, value: value})
		} else {
			tokens = append(tokens, token{kind: "bare", value: p})
		}
	}
	return tokens
}

// parseQuery translates a notmuch-style query into a SQL WHERE clause and parameters.
func parseQuery(query string) (where string, params []interface{}, err error) {
	tokens := tokenize(query)

	var clauses []string
	var pathClauses []string
	var pathParams []interface{}

	for _, tok := range tokens {
		switch tok.kind {
		case "star":
			// No filter
			return "", nil, nil

		case "field", "not_field":
			clause, p, err := fieldToSQL(tok)
			if err != nil {
				return "", nil, err
			}
			// Collect path: clauses separately — multiple accounts should be OR-ed
			if tok.field == "path" && tok.kind == "field" && clause != "1=1" {
				pathClauses = append(pathClauses, clause)
				pathParams = append(pathParams, p...)
			} else {
				clauses = append(clauses, clause)
				params = append(params, p...)
			}

		case "bare":
			clauses = append(clauses, "m.id IN (SELECT rowid FROM messages_fts WHERE messages_fts MATCH ?)")
			params = append(params, tok.value)
		}
	}

	// Multiple path: filters are OR-ed (match any of the accounts)
	if len(pathClauses) == 1 {
		clauses = append(clauses, pathClauses[0])
		params = append(params, pathParams...)
	} else if len(pathClauses) > 1 {
		clauses = append(clauses, "("+strings.Join(pathClauses, " OR ")+")")
		params = append(params, pathParams...)
	}

	return strings.Join(clauses, " AND "), params, nil
}

// fieldToSQL converts a single field:value token into a SQL clause.
func fieldToSQL(tok token) (string, []interface{}, error) {
	negate := tok.kind == "not_field"
	var clause string
	var params []interface{}

	switch tok.field {
	case "from":
		clause = "m.from_addr LIKE ?"
		params = []interface{}{"%" + tok.value + "%"}

	case "to":
		clause = "m.to_addrs LIKE ?"
		params = []interface{}{"%" + tok.value + "%"}

	case "subject":
		clause = "m.id IN (SELECT rowid FROM messages_fts WHERE messages_fts MATCH ?)"
		params = []interface{}{"subject:" + tok.value}

	case "tag":
		if negate {
			return "NOT EXISTS (SELECT 1 FROM tags WHERE tags.message_id = m.id AND tags.tag = ?)",
				[]interface{}{tok.value}, nil
		}
		return "EXISTS (SELECT 1 FROM tags WHERE tags.message_id = m.id AND tags.tag = ?)",
			[]interface{}{tok.value}, nil

	case "date":
		return parseDateRange(tok.value)

	case "path":
		account := extractAccountFromPath(tok.value)
		if account != "" {
			clause = "m.account LIKE ?"
			params = []interface{}{"%" + account + "%"}
		} else {
			return "1=1", nil, nil
		}

	case "folder", "thread", "id", "mimetype":
		// Notmuch-specific fields — skip (no equivalent in store)
		return "1=1", nil, nil

	default:
		return "", nil, fmt.Errorf("unknown query field: %q", tok.field)
	}

	if negate {
		clause = "NOT (" + clause + ")"
	}
	return clause, params, nil
}

// parseDateRange parses date:FROM..TO into a SQL BETWEEN clause.
// Supports formats: 2024-01, 2024-01-15
func parseDateRange(value string) (string, []interface{}, error) {
	parts := strings.SplitN(value, "..", 2)
	if len(parts) != 2 {
		return "", nil, fmt.Errorf("date range must be FROM..TO, got %q", value)
	}

	from, err := parseDate(parts[0])
	if err != nil {
		return "", nil, fmt.Errorf("parse date from: %w", err)
	}
	to, err := parseDateEnd(parts[1])
	if err != nil {
		return "", nil, fmt.Errorf("parse date to: %w", err)
	}

	return "m.date BETWEEN ? AND ?", []interface{}{from, to}, nil
}

// parseDate parses a date string into a Unix timestamp (start of day/month).
func parseDate(s string) (int64, error) {
	for _, layout := range []string{"2006-01-02", "2006-01"} {
		t, err := time.Parse(layout, s)
		if err == nil {
			return t.Unix(), nil
		}
	}
	return 0, fmt.Errorf("unsupported date format: %q", s)
}

// parseDateEnd parses a date string into a Unix timestamp (end of day/month).
func parseDateEnd(s string) (int64, error) {
	for _, layout := range []string{"2006-01-02", "2006-01"} {
		t, err := time.Parse(layout, s)
		if err == nil {
			if layout == "2006-01" {
				// End of month
				t = t.AddDate(0, 1, 0).Add(-time.Second)
			} else {
				// End of day
				t = t.Add(24*time.Hour - time.Second)
			}
			return t.Unix(), nil
		}
	}
	return 0, fmt.Errorf("unsupported date format: %q", s)
}

// extractAccountFromPath extracts the account folder name from a notmuch path pattern.
// e.g. "habric/**" → "habric", "jsLab/INBOX" → "jsLab"
func extractAccountFromPath(value string) string {
	value = strings.TrimRight(value, "*")
	value = strings.TrimRight(value, "/")
	if idx := strings.Index(value, "/"); idx > 0 {
		return value[:idx]
	}
	return value
}

// formatDateRelative formats a Unix timestamp as a human-readable relative date.
func formatDateRelative(ts int64) string {
	t := time.Unix(ts, 0)
	now := time.Now()
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	yesterday := today.AddDate(0, 0, -1)
	weekAgo := today.AddDate(0, 0, -7)

	switch {
	case t.After(today):
		return t.Format("15:04")
	case t.After(yesterday):
		return "Yesterday " + t.Format("15:04")
	case t.After(weekAgo):
		return t.Format("Mon 15:04")
	case t.Year() == now.Year():
		return t.Format("Jan 02")
	default:
		return t.Format("2006-01-02")
	}
}
