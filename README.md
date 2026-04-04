<p align="center">
  <img src="docs/logo.png" width="150" />
</p>

<h1 align="center">Durian</h1>

<p align="center">
  A native macOS email client with vim-style navigation.
</p>

![Status](https://img.shields.io/badge/status-alpha-orange)
![Maintained](https://img.shields.io/badge/maintained-yes-green)
![License](https://img.shields.io/badge/license-MIT-blue)

<p align="center">
  <img src="docs/screenshot-light.png" width="800" />
</p>

<details>
<summary>Dark mode & compose</summary>

<p align="center">
  <img src="docs/screenshot-dark.png" width="800" />
  <br><br>
  <img src="docs/screenshot-compose.png" width="600" />
</p>
</details>

Tags instead of folders. Full-text search. Multi-account with OAuth (Gmail, Microsoft 365) and password auth. IMAP sync to a local SQLite store — fast offline search, no Maildir. Configurable keybindings, filter rules, and HTML signatures. All in a SwiftUI app backed by a Go CLI.

> **Early Alpha** — Expect bugs and breaking changes. No security audit. Use at your own risk.
> This is a side project — features, improvements, and bug fixes happen as time allows.

## Install

### macOS (Homebrew)

```bash
brew tap julion2/tap
brew install durian             # CLI (required — the GUI uses it as backend)
brew install --cask durian      # GUI
```

### Linux (CLI only)

```bash
brew tap julion2/tap
brew install durian
```

Or download pre-built binaries from [GitHub Releases](https://github.com/julion2/Durian/releases). Or build from source (see below).

## Build from Source

### Requirements

- **macOS:** macOS 26+, Xcode 26+ (CLI + GUI)
- **Linux:** Go 1.24+, `secret-tool` (libsecret) for credential storage (CLI only)
- [Bazelisk](https://github.com/bazelbuild/bazelisk)

### Build & Install

```bash
bazel build //cli/cmd/durian    # CLI (macOS & Linux)
bazel build //macos:Durian        # GUI (macOS only, debug)
bazel build -c opt //macos:Durian # GUI (macOS only, release)

./cli/install.sh                # build & install CLI to /usr/local/bin
./gui/install.sh                # build & install GUI to /Applications
./gui/run.sh                    # build & run debug GUI (DurianNightly.app)
```

## Test

```bash
bazel test //cli/...            # CLI tests
bazel test //macos/...            # GUI tests (requires Xcode 26)
```

## CLI

```bash
durian auth login work          # authenticate (OAuth or password)
durian auth status              # show auth status
durian sync work                # sync an account
durian search "tag:inbox" -l 10 # search
durian search "date:today"      # relative date search
```

## Config

All configuration lives in `~/.config/durian/` (or `$XDG_CONFIG_HOME/durian/`):

| File | Purpose |
|------|---------|
| `config.toml` | Accounts, signatures, settings |
| `profiles.toml` | Sidebar profiles (account groups, folders) |
| `keymaps.toml` | Vim-style keyboard shortcuts |
| `rules.toml` | Client-side filter rules |

Examples:
- [config-example.toml](docs/config-example.toml) — Accounts, signatures, settings
- [profiles-example.toml](docs/profiles-example.toml) — Sidebar profiles and folders
- [keymaps-example.toml](docs/keymaps-example.toml) — Keyboard shortcuts
- [rules-example.toml](docs/rules-example.toml) — Filter rules

## Logs

```bash
# GUI (Swift → os_log)
log stream --level debug --predicate 'subsystem == "org.js-lab.durian.nightly"'
log stream --level debug --predicate 'subsystem == "org.js-lab.durian"'

# CLI (Go → slog)
tail -f ~/.config/durian/serve.log    # durian serve logs
durian sync --debug                   # debug output on stderr
```

## Docs

- [OAuth Setup](docs/OAUTH_SETUP.md) — Gmail & Microsoft 365
- [Password Setup](docs/PASSWORD_SETUP.md) — IMAP/SMTP with password auth
- [Tag Sync](docs/TAG_SYNC.md) — Multi-machine tag sync via self-hosted server
- [Vim Compose](docs/vim-compose.md) — Vim keybindings in the compose editor

## Contributing

Found a bug or have a feature request? [Open an issue](https://github.com/julion2/Durian/issues).

## License

[MIT](LICENSE)
