# Durian

Email client: Go CLI backend + Swift macOS GUI.

## Build & Run

- **CLI:** `bazel build //cli/cmd/durian` → install: `cli/install.sh` (copies to /usr/local/bin)
- **GUI:** `bazel build //macos:Durian` → dev run: `macos/run.sh` (debug build → `/Applications/DurianNightly.app`) → install: `macos/install.sh` (release build → `/Applications/Durian.app`)
- **Tests:** `bazel test //cli/...` (CLI) / `bazel test //macos/...` (GUI, requires Xcode 26) / `bazel test //...` (all)
- **Integration Tests:** `bazel test //integration:integration_test` (starts real server, validates API contract via curl+jq)
- **Validate Config:** `durian validate` (checks config.pkl, rules.pkl, profiles.pkl, keymaps.pkl, groups.pkl)
- **Logs (GUI/Swift):** `log stream --level debug --predicate 'subsystem == "org.js-lab.durian.nightly"'` (nightly) / `subsystem == "org.js-lab.durian"` (release)
- **Logs (CLI/Go):** `~/.local/state/durian/serve.log` (or `$XDG_STATE_HOME/durian/serve.log`; truncated on each `durian serve` start). Default: Info+, with `--debug`: Debug+. Other commands: Error → stderr, with `--debug`: Debug+ → stderr.
- **Data:** `~/.local/share/durian/` (or `$XDG_DATA_HOME/durian/`) — `email.db`, `contacts.db`

## Project Structure

- Config dir: `~/.config/durian/` (or `$XDG_CONFIG_HOME/durian/`) — files: `config.pkl`, `keymaps.pkl`, `profiles.pkl`, `rules.pkl`, `groups.pkl` (see `docs/*-example.pkl`). Config uses [Apple Pkl](https://pkl-lang.org) — evaluated via `pkl eval --format json` at runtime. Schemas are embedded in the binary (`schema/*.pkl`) and provided via `--module-path`. Requires `pkl` CLI (`brew install pkl`).
- `cli/` — Go 1.24 (Cobra), IMAP sync, SMTP send, SQLite store, HTTP API server
  - `cli/cmd/durian/` — CLI commands (sync, send, serve, search, tag, contacts, draft, auth)
  - `cli/internal/` — Internal packages (config, imap, smtp, handler, store, oauth, mail, encoding, contacts, draft, keychain, protocol)
- `macos/` — Swift macOS app (SwiftUI)
  - `macos/durian/Managers/` — Singleton `ObservableObject` managers (`@MainActor`, `.shared`)
  - `macos/durian/Views/` — SwiftUI view components
  - `macos/durian/Models/` — Data structs
  - `macos/durian/Network/` — `NotmuchBackend` (HTTP client to CLI server)
  - `macos/durian/Keymaps/` — Vim-style key sequence engine
  - `macos/durian/Utilities/` — Helper extensions
- `openapi.yaml` — API spec for GUI ↔ CLI communication

## CI

- GitHub Actions: `.github/workflows/test.yml`
- **CLI job** runs on `ubuntu-latest` (Go tests + build)
- **GUI job** runs on `macos-26` with `DEVELOPER_DIR=/Applications/Xcode_26.4.1.app/...` (macOS 26 SDK required for `glassEffect` etc.)

## Code Style

### Go
- Imports: stdlib → external → internal
- Errors: wrap with `fmt.Errorf("context: %w", err)`
- Naming: camelCase/PascalCase
- Logging: stdlib `log/slog` with structured key-value pairs. Use `slog.Debug/Info/Warn/Error("Message", "key", value)`. Add `"module", "NAME"` for context (e.g. `"module", "SYNC"`). Never use `log.Printf` or `fmt.Printf` for logging.

### Swift
- Imports: Foundation/SwiftUI first
- Use `// MARK:` sections
- Managers: singleton with `static let shared`, `@MainActor`, `@Published` for state
- User-facing errors: `ErrorManager.shared.showWarning/showCritical` (toast banners)
- Logging: `Log.debug("PREFIX", "message")` via `os_log` wrapper (`macos/durian/Utilities/Log.swift`). Levels: `.debug` (trace), `.info` (notable events), `.warning` (recoverable), `.error` (failures). Prefix = uppercase module name (e.g. `SYNC`, `EMAIL`, `KEYMAPS`, `CONFIG`). Never use `print()` — it goes to `/dev/null` when launched from `/Applications`.

### General
- UI text: English (all user-facing strings)
- Logs: English, prefixed

## Commit Style

Format: `<type>(<scope>): <short description>`

- **Types:** feat, fix, doc, refactor, chore, test, ci
- **Scopes:** `go-*` for Go (e.g. `go-imap`, `go-smtp`), `swift-*` for Swift (e.g. `swift-compose`, `swift-sync`)
- Imperative present tense
- No Co-Authored-By line

## Key Architecture

- GUI ↔ CLI: HTTP API on `localhost:9723` (GUI starts CLI via `durian serve`). GUI must never access the database directly — always go through the durian CLI API.
- State management: Combine publishers, `@Published` properties
- Navigation: Custom `KeySequenceEngine` for vim bindings
- Error display: `ErrorManager` → `ErrorBannerView` (bottom-right toast, warnings auto-dismiss 5s)
