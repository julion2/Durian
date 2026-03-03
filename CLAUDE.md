# Durian

Email client: Go CLI backend + Swift macOS GUI.

## Build & Run

- **CLI:** `bazel build //cli/cmd/durian` → install: `cli/install.sh` (copies to /usr/local/bin)
- **GUI:** `bazel build //gui:Durian` → run: `bazel run //gui:Durian` → install: `gui/install.sh` (copies to /Applications)
- **Tests:** `bazel test //cli/...` (CLI) / `bazel test //gui/...` (GUI) / `bazel test //...` (all)

## Project Structure

- Config dir: `~/.config/durian/` (`config.toml`, `keymaps.toml`, `profiles.toml`; see `docs/config-example.toml`)
- `cli/` — Go 1.24 (Cobra), IMAP sync, SMTP send, notmuch search, HTTP API server
  - `cli/cmd/durian/` — CLI commands (sync, send, serve, search, tag, contacts, draft, auth)
  - `cli/internal/` — Internal packages (config, imap, smtp, handler, notmuch, oauth, mail, encoding, contacts, draft, keychain, protocol, debug)
- `gui/` — Swift macOS app (SwiftUI)
  - `gui/durian/Managers/` — Singleton `ObservableObject` managers (`@MainActor`, `.shared`)
  - `gui/durian/Views/` — SwiftUI view components
  - `gui/durian/Models/` — Data structs
  - `gui/durian/Network/` — `NotmuchBackend` (HTTP client to CLI server)
  - `gui/durian/Keymaps/` — Vim-style key sequence engine
  - `gui/durian/Utilities/` — Helper extensions
- `openapi.yaml` — API spec for GUI ↔ CLI communication

## Code Style

### Go
- Imports: stdlib → external → internal
- Errors: wrap with `fmt.Errorf("context: %w", err)`
- Naming: camelCase/PascalCase

### Swift
- Imports: Foundation/SwiftUI first
- Use `// MARK:` sections
- Managers: singleton with `static let shared`, `@MainActor`, `@Published` for state
- User-facing errors: `ErrorManager.shared.showWarning/showCritical` (toast banners)
- Debug: `print("PREFIX: message")` — prefix = uppercase module name (e.g. `SYNC:`, `EMAIL:`, `KEYMAPS:`, `CONFIG:`). New code should follow this pattern.

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

- GUI ↔ CLI: HTTP API on `localhost:9723` (GUI starts CLI via `durian serve`). GUI must never call notmuch directly — always go through the durian CLI API.
- State management: Combine publishers, `@Published` properties
- Navigation: Custom `KeySequenceEngine` for vim bindings
- Error display: `ErrorManager` → `ErrorBannerView` (bottom-right toast, warnings auto-dismiss 5s)
