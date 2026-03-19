# Durian

Email client: Go CLI backend + Swift macOS GUI.

## Build & Run

- **CLI:** `bazel build //cli/cmd/durian` → install: `cli/install.sh` (copies to /usr/local/bin)
- **GUI:** `bazel build //gui:Durian` → dev run: `gui/run.sh` (debug build → `/Applications/DurianNightly.app`) → install: `gui/install.sh` (release build → `/Applications/Durian.app`)
- **Tests:** `bazel test //cli/...` (CLI) / `bazel test //gui/...` (GUI, requires Xcode 26) / `bazel test //...` (all)
- **CI Tests (GUI):** `bazel test //gui:ci_config_test //gui:ci_profile_test //gui:ci_banner_manager_test //gui:ci_model_test` (uses `durian_core` target, no Views, works on Xcode 16+)
- **Logs (GUI/Swift):** `log stream --level debug --predicate 'subsystem == "org.js-lab.durian.nightly"'` (nightly) / `subsystem == "org.js-lab.durian"` (release)
- **Logs (CLI/Go):** `~/.config/durian/serve.log` (truncated on each `durian serve` start). Default: Info+, with `--debug`: Debug+. Other commands: Error → stderr, with `--debug`: Debug+ → stderr.

## Project Structure

- Config dir: `~/.config/durian/` (`config.toml`, `keymaps.toml`, `profiles.toml`, `rules.toml`; see `docs/config-example.toml`)
- `cli/` — Go 1.24 (Cobra), IMAP sync, SMTP send, SQLite store, HTTP API server
  - `cli/cmd/durian/` — CLI commands (sync, send, serve, search, tag, contacts, draft, auth)
  - `cli/internal/` — Internal packages (config, imap, smtp, handler, store, oauth, mail, encoding, contacts, draft, keychain, protocol)
- `gui/` — Swift macOS app (SwiftUI)
  - `gui/durian/Managers/` — Singleton `ObservableObject` managers (`@MainActor`, `.shared`)
  - `gui/durian/Views/` — SwiftUI view components
  - `gui/durian/Models/` — Data structs
  - `gui/durian/Network/` — `NotmuchBackend` (HTTP client to CLI server)
  - `gui/durian/Keymaps/` — Vim-style key sequence engine
  - `gui/durian/Utilities/` — Helper extensions
- `openapi.yaml` — API spec for GUI ↔ CLI communication

## CI

- GitHub Actions: `.github/workflows/test.yml`
- **CLI job** runs on `ubuntu-latest` (Go tests + build)
- **GUI job** runs on `macos-15` with `ci_*` test targets using `durian_core` (models/managers/utilities, no Views)
- Views use macOS 26 APIs (`glassEffect`) requiring Xcode 26, but `rules_swift` `test_discoverer` crashes on Xcode 26. The `durian_core` target splits out testable code that compiles on Xcode 16+.
- When adding new GUI tests: add both a regular `swift_test` (deps `durian_testlib`) and a `ci_*` variant (deps `durian_core`) in `gui/BUILD.bazel`

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
- Logging: `Log.debug("PREFIX", "message")` via `os_log` wrapper (`gui/durian/Utilities/Log.swift`). Levels: `.debug` (trace), `.info` (notable events), `.warning` (recoverable), `.error` (failures). Prefix = uppercase module name (e.g. `SYNC`, `EMAIL`, `KEYMAPS`, `CONFIG`). Never use `print()` — it goes to `/dev/null` when launched from `/Applications`.

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
