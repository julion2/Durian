# Spec: Cobra CLI für Durian Mail Client

## Context
Durian ist aktuell nur als JSON-Protocol-Server nutzbar (stdin/stdout), primär für die GUI-Integration. Diese Spezifikation beschreibt die Erweiterung um eine vollständige Cobra-basierte CLI, die sowohl direktes Terminal-Interface als auch GUI-Kompatibilität bietet.

**Warum:** Nutzer wollen Durian direkt im Terminal verwenden können, ohne JSON manuell schreiben zu müssen.

**Was:** Integration von github.com/spf13/cobra für Command-Line-Interface mit Subcommands für search, show, tag, send und serve.

## Requirements

### Ubiquitous Requirements
- **REQ-001:** The system shall use github.com/spf13/cobra for CLI command structure
- **REQ-002:** The system shall maintain backward compatibility with existing JSON protocol for GUI communication
- **REQ-003:** The system shall reuse existing handler package logic for all command implementations
- **REQ-004:** The system shall provide help text for all commands via `--help` flag
- **REQ-005:** The system shall display version information via `--version` flag
- **REQ-006:** The system shall read notmuch configuration from default location `~/.config/durian/config.toml` (if implemented) or rely on notmuch's own config

### Event-driven Requirements
- **REQ-007:** When user executes `durian search <query>`, the system shall execute notmuch search and display results in table format
- **REQ-008:** When user executes `durian show <thread-id>`, the system shall display mail content for the specified thread
- **REQ-009:** When user executes `durian tag <query> <tags...>`, the system shall apply tag modifications to matching messages
- **REQ-010:** When user executes `durian serve`, the system shall start JSON protocol server mode (current behavior)
- **REQ-011:** When user executes `durian send`, the system shall display "not yet implemented" message
- **REQ-012:** When user provides `--limit <n>` flag to search command, the system shall limit results to n entries
- **REQ-013:** When user provides `--html` flag to show command, the system shall prefer HTML body over plain text
- **REQ-014:** When user provides `--json` flag to any command, the system shall output results in JSON format
- **REQ-015:** When user provides `--config <path>` global flag, the system shall use specified config file path

### State-driven Requirements
- **REQ-016:** While in serve mode, the system shall process JSON commands from stdin and write JSON responses to stdout
- **REQ-017:** While processing search results, the system shall format output as ASCII table with columns: Thread-ID, Subject, From, Date, Tags
- **REQ-018:** While processing show command, the system shall format output as human-readable mail with headers and body

### Unwanted Behavior Requirements
- **REQ-019:** If no query is provided to search command, the system shall return error "query required"
- **REQ-020:** If no thread-id is provided to show command, the system shall return error "thread-id required"
- **REQ-021:** If no tags are provided to tag command, the system shall return error "at least one tag required"
- **REQ-022:** If no query is provided to tag command, the system shall return error "query required"
- **REQ-023:** If notmuch backend returns error, the system shall display user-friendly error message and exit with non-zero status
- **REQ-024:** If thread-id does not exist, the system shall return error "thread not found"
- **REQ-025:** If tag format is invalid (neither +tag nor -tag), the system shall return error "invalid tag format: must start with + or -"
- **REQ-026:** If config file is specified but doesn't exist, the system shall return error "config file not found: <path>"

### Optional Requirements
- **REQ-027:** Where `--json` flag is provided, the system shall output data in machine-readable JSON format matching protocol.Response structure

## Acceptance Criteria

### Search Command
- **AC-001:** Given user executes `durian search "tag:inbox"`, when notmuch returns results, then system shall display table with Thread-ID, Subject, From, Date, Tags columns
- **AC-002:** Given user executes `durian search "tag:inbox" --limit 10`, when notmuch returns results, then system shall display maximum 10 results
- **AC-003:** Given user executes `durian search "tag:inbox" --json`, when notmuch returns results, then system shall output JSON array of mail.Mail structs
- **AC-004:** Given user executes `durian search` without query, when command runs, then system shall exit with error "query required"
- **AC-005:** Given user executes `durian search "nonexistent:tag"`, when notmuch returns empty result, then system shall display "No results found"

### Show Command
- **AC-006:** Given user executes `durian show <thread-id>`, when thread exists, then system shall display formatted mail with From, To, Subject, Date headers and plain text body
- **AC-007:** Given user executes `durian show <thread-id> --html`, when thread has HTML body, then system shall display HTML content
- **AC-008:** Given user executes `durian show <thread-id> --json`, when thread exists, then system shall output JSON mail.MailContent struct
- **AC-009:** Given user executes `durian show` without thread-id, when command runs, then system shall exit with error "thread-id required"
- **AC-010:** Given user executes `durian show invalidthread`, when thread doesn't exist, then system shall exit with error "thread not found"

### Tag Command
- **AC-011:** Given user executes `durian tag "thread:abc123" +read -inbox`, when messages exist, then system shall apply tags and display "Tags applied successfully"
- **AC-012:** Given user executes `durian tag "thread:abc123" +read`, when messages exist, then system shall add "read" tag
- **AC-013:** Given user executes `durian tag "thread:abc123" -inbox`, when messages exist, then system shall remove "inbox" tag
- **AC-014:** Given user executes `durian tag` without query, when command runs, then system shall exit with error "query required"
- **AC-015:** Given user executes `durian tag "thread:abc123"` without tags, when command runs, then system shall exit with error "at least one tag required"
- **AC-016:** Given user executes `durian tag "thread:abc123" invalid`, when tag doesn't start with +/-, then system shall exit with error "invalid tag format"

### Serve Command
- **AC-017:** Given user executes `durian serve`, when JSON commands arrive on stdin, then system shall process them and write JSON responses to stdout (current behavior)
- **AC-018:** Given user executes `durian serve`, when stdin is closed, then system shall exit gracefully

### Send Command (Placeholder)
- **AC-019:** Given user executes `durian send`, when command runs, then system shall display "send command not yet implemented"
- **AC-020:** Given user executes `durian send --help`, when command runs, then system shall display help text for future SMTP functionality

### Global Flags
- **AC-021:** Given user executes `durian --help`, when command runs, then system shall display list of all available commands
- **AC-022:** Given user executes `durian search --help`, when command runs, then system shall display search command help with examples
- **AC-023:** Given user executes `durian --version`, when command runs, then system shall display version number (e.g., "durian v0.1.0")
- **AC-024:** Given user executes `durian --config /custom/path/config.toml search "tag:inbox"`, when command runs, then system shall use custom config path (future: currently no-op as config not implemented)

## Edge Cases

### EC-001: Empty Search Results
- **Scenario:** User searches for query with zero matches
- **Handling:** Display "No results found" instead of empty table

### EC-002: Very Long Subject Lines
- **Scenario:** Mail subject exceeds terminal width
- **Handling:** Truncate subject with "..." at terminal width limit

### EC-003: Missing Notmuch Binary
- **Scenario:** notmuch command not found in PATH
- **Handling:** Exit with error "notmuch not found: please install notmuch"

### EC-004: Malformed Notmuch Query
- **Scenario:** User provides syntactically invalid notmuch query
- **Handling:** Display notmuch error message and exit with non-zero status

### EC-005: Multiple Threads Match in Show
- **Scenario:** Thread-ID is ambiguous or query matches multiple threads
- **Handling:** Show first message (current behavior via GetFiles with limit=1)

### EC-006: HTML-only Mail with --html Flag Missing
- **Scenario:** Mail has only HTML body, user doesn't use --html flag
- **Handling:** Display plain text conversion or "[HTML content - use --html flag to view]"

### EC-007: Concurrent Serve Mode
- **Scenario:** User runs multiple `durian serve` instances
- **Handling:** Each instance operates independently (no shared state)

### EC-008: Tag Command on Zero Matches
- **Scenario:** Tag query matches zero messages
- **Handling:** Display "No messages matched query" (notmuch behavior)

### EC-009: Terminal Not a TTY
- **Scenario:** Output is piped to file or another program
- **Handling:** Disable table formatting, use simple newline-separated output

### EC-010: Unicode in Mail Headers
- **Scenario:** From/Subject contains emoji or non-ASCII characters
- **Handling:** Display correctly using existing encoding package (already handles this)

### EC-011: Large Result Sets
- **Scenario:** Search returns 1000+ results without --limit
- **Handling:** Default limit to 50 (REQ-012, existing handler behavior)

### EC-012: Config File Permissions
- **Scenario:** Config file exists but is not readable
- **Handling:** Exit with error "config file not readable: <path>"

## Tasks

### Phase 1: Cobra Setup (M)
1. **[T-001]** Add `github.com/spf13/cobra` dependency to go.mod (S) – enables REQ-001
2. **[T-002]** Create `cli/cmd/durian/root.go` with root command and global flags (M) – implements REQ-004, REQ-005, REQ-006, REQ-015
   - Define global `--version`, `--help`, `--config` flags
   - Set version string (read from build-time variable or const)
   - Configure Cobra settings (SilenceUsage, SilenceErrors)
3. **[T-003]** Refactor `main.go` to use Cobra root command (S) – integrates REQ-001

### Phase 2: Serve Command (S)
4. **[T-004]** Create `cli/cmd/durian/serve.go` with serve subcommand (S) – implements REQ-010, REQ-016
   - Move existing JSON protocol server logic into serve command
   - Validates AC-017, AC-018

### Phase 3: Search Command (M)
5. **[T-005]** Create `cli/cmd/durian/search.go` with search subcommand (M) – implements REQ-007, REQ-012, REQ-019
   - Add `--limit` flag (default 50)
   - Add `--json` flag for JSON output (REQ-014, REQ-027)
   - Implement table formatter for terminal output (REQ-017)
6. **[T-006]** Implement ASCII table formatter utility in `cli/internal/format/table.go` (M) – supports REQ-017
   - Handle EC-002 (subject truncation)
   - Handle EC-009 (TTY detection)
7. **[T-007]** Add search command tests (M) – validates AC-001 through AC-005

### Phase 4: Show Command (M)
8. **[T-008]** Create `cli/cmd/durian/show.go` with show subcommand (M) – implements REQ-008, REQ-013, REQ-020, REQ-024
   - Add `--html` flag
   - Add `--json` flag
   - Implement mail content formatter (REQ-018)
9. **[T-009]** Implement mail formatter utility in `cli/internal/format/mail.go` (S) – supports REQ-018
   - Handle EC-006 (HTML-only mails)
10. **[T-010]** Add show command tests (M) – validates AC-006 through AC-010

### Phase 5: Tag Command (M)
11. **[T-011]** Create `cli/cmd/durian/tag.go` with tag subcommand (M) – implements REQ-009, REQ-021, REQ-022, REQ-025
    - Validate tag format (+/- prefix)
    - Support multiple tags as variadic args
12. **[T-012]** Add tag validation logic (S) – implements REQ-025, validates AC-016
13. **[T-013]** Add tag command tests (M) – validates AC-011 through AC-016

### Phase 6: Send Command Placeholder (S)
14. **[T-014]** Create `cli/cmd/durian/send.go` with placeholder implementation (S) – implements REQ-011
    - Display "not yet implemented" message
    - Add help text describing future SMTP functionality
    - Validates AC-019, AC-020

### Phase 7: Error Handling & Polish (M)
15. **[T-015]** Implement user-friendly error wrapper in `cli/internal/format/errors.go` (M) – implements REQ-023
    - Map backend errors to readable messages
    - Handle EC-003 (notmuch not found)
    - Handle EC-004 (malformed query)
16. **[T-016]** Add exit code handling to all commands (S) – supports REQ-023
17. **[T-017]** Add example usage to all command help texts (S) – improves REQ-004

### Phase 8: Integration Testing (M)
18. **[T-018]** Add end-to-end tests with mock notmuch backend (L) – validates all AC criteria
19. **[T-019]** Test JSON output mode for all commands (M) – validates REQ-027, AC-003, AC-008
20. **[T-020]** Test edge cases with integration tests (L) – validates EC-001 through EC-012

### Phase 9: Documentation (S)
21. **[T-021]** Add README section with CLI usage examples (S)
22. **[T-022]** Update build instructions for CLI binary (S)

**Estimated Total Effort:** 2-3 days for experienced Go developer

## Example Usage

### Search
```bash
# Basic search
$ durian search "tag:inbox"
Thread-ID          Subject                    From              Date         Tags
0000000000000001   Re: Meeting tomorrow       alice@example.com 2 hours ago  inbox,unread
0000000000000002   Project update             bob@example.com   yesterday    inbox

# With limit
$ durian search "tag:inbox" --limit 5

# JSON output
$ durian search "tag:inbox" --json
[{"thread_id":"0000000000000001","subject":"Re: Meeting tomorrow",...}]
```

### Show
```bash
# Show mail
$ durian show 0000000000000001
From: alice@example.com
To: me@example.com
Subject: Re: Meeting tomorrow
Date: 2025-12-18 10:30:00

Hi,

Yes, tomorrow at 2pm works for me.

Best,
Alice

# Show HTML version
$ durian show 0000000000000001 --html

# JSON output
$ durian show 0000000000000001 --json
{"from":"alice@example.com","to":"me@example.com",...}
```

### Tag
```bash
# Add/remove tags
$ durian tag "thread:0000000000000001" +read -inbox
Tags applied successfully

# Multiple tags
$ durian tag "from:alice@example.com" +important +followup
```

### Serve
```bash
# Start JSON protocol server (for GUI)
$ durian serve
# ... reads JSON from stdin, writes to stdout ...
```

### Send (Placeholder)
```bash
$ durian send
send command not yet implemented
```

### Help
```bash
# Root help
$ durian --help
Durian - A fast mail client using notmuch

Usage:
  durian [command]

Available Commands:
  search      Search for mails
  show        Show mail content
  tag         Apply tags to mails
  send        Send a mail (not yet implemented)
  serve       Start JSON protocol server

Flags:
  -h, --help            help for durian
  -v, --version         version for durian
  -c, --config string   config file (default "~/.config/durian/config.toml")

Use "durian [command] --help" for more information about a command.

# Command help
$ durian search --help
Search for mails using notmuch query syntax

Usage:
  durian search <query> [flags]

Examples:
  durian search "tag:inbox"
  durian search "from:alice@example.com" --limit 10
  durian search "date:today" --json

Flags:
  -h, --help         help for search
  -l, --limit int    limit number of results (default 50)
      --json         output results as JSON

Global Flags:
  -c, --config string   config file (default "~/.config/durian/config.toml")
```

### Version
```bash
$ durian --version
durian version 0.1.0
```

## Open Questions

1. **Q1:** Should search table output include message count/total in header?
   - **Impact:** UX improvement, requires additional notmuch query
   - **Recommendation:** Defer to v2, display count only if easily available

2. **Q2:** Should `durian show` support multiple thread-IDs or only single?
   - **Impact:** API design, affects REQ-008
   - **Recommendation:** Start with single thread-ID, add multi-show in v2 if needed

3. **Q3:** Config file format and content - what should be configurable?
   - **Impact:** Affects REQ-006, REQ-015, REQ-026
   - **Recommendation:** Start with empty/optional config, add settings as needed (e.g., default limit, output format preferences)

4. **Q4:** Should `--json` output use protocol.Response structure or raw data?
   - **Impact:** Affects REQ-027, AC-003, AC-008
   - **Recommendation:** Use raw data (mail.Mail[], mail.MailContent) for CLI, keep protocol.Response for serve mode only

5. **Q5:** Color output support (e.g., colorize tags, highlight unread)?
   - **Impact:** UX improvement, adds dependency (e.g., fatih/color)
   - **Recommendation:** Defer to v2, add `--color` flag when implemented

6. **Q6:** Should serve mode log to stderr for debugging?
   - **Impact:** Debugging experience, must not pollute stdout
   - **Recommendation:** Add optional `--verbose` flag to serve command for stderr logging

7. **Q7:** Should tag command support interactive mode (select from search results)?
   - **Impact:** Major UX feature, requires interactive terminal library
   - **Recommendation:** Out of scope for v1, consider for v2

## Technical Notes

### Dependency Injection
- Maintain existing dependency structure: `main.go` wires `notmuch.Client` → `handler.Handler` → Cobra commands
- Pass handler to each command via flag or package-level variable

### Testing Strategy
- Unit tests: Each command with mock handler
- Integration tests: Full flow with mock notmuch backend (use existing `notmuch.MockClient`)
- E2E tests: Real notmuch with test maildir (optional, CI environment dependent)

### Backward Compatibility
- `durian serve` must behave identically to current `durian` (no args) behavior
- Consider: Make serve the default command if no args provided (for backward compat)

### Output Formatting
- Table library options: 
  - `olekukonko/tablewriter` (popular, actively maintained)
  - `jedib0t/go-pretty/table` (feature-rich, good Unicode support)
  - Custom implementation (lightweight, full control)
- Recommendation: Start with custom implementation for tables (simple, no deps), evaluate libraries if complexity grows

### Version Management
- Use `-ldflags "-X main.version=..."` at build time
- Store version in `cli/cmd/durian/version.go` as variable

## Success Metrics

- [ ] All 24 Acceptance Criteria pass
- [ ] Zero regression in existing GUI/serve mode functionality
- [ ] All 12 Edge Cases handled gracefully
- [ ] Test coverage >80% for new command code
- [ ] CLI usable without reading documentation (intuitive help text)
- [ ] Performance: search/show commands complete in <500ms for typical queries
