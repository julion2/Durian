<p align="center">
  <img src="docs/logo.png" width="150" />
</p>

<h1 align="center">Durian</h1>

<p align="center">
  A macOS email client for power users. Vim-style navigation, IMAP + SQLite backend.
</p>

![Status](https://img.shields.io/badge/status-alpha-orange)
![Maintained](https://img.shields.io/badge/maintained-yes-green)
![License](https://img.shields.io/badge/license-MIT-blue)

> **Early Alpha** — Expect bugs and breaking changes. No security audit. Use at your own risk.
>
> This is a side project — features, improvements, and bug fixes happen as time allows.

## Install

```bash
brew tap julion2/tap
brew install durian             # CLI only
brew install --cask durian      # GUI (macOS app)
```

## Build from Source

### Requirements

- macOS 26+ (for GUI, SwiftUI)
- [Bazelisk](https://github.com/bazelbuild/bazelisk) (`brew install bazelisk`) — manages Bazel version via `.bazelversion`
- Xcode 26+ (for GUI builds)
- Go 1.24+ (managed by Bazel, no manual install needed)

### Build & Install

```bash
bazel build //cli/cmd/durian    # CLI
bazel build //gui:Durian        # GUI (debug)
bazel build -c opt //gui:Durian # GUI (release)

./cli/install.sh                # build & install CLI to /usr/local/bin
./gui/install.sh                # build & install GUI to /Applications
./gui/run.sh                    # build & run debug GUI (DurianNightly.app)
```

## Test

```bash
bazel test //cli/...            # CLI tests
bazel test //gui/...            # GUI tests (requires Xcode 26)
```

## CLI Usage

```bash
durian auth login work          # authenticate (OAuth or password)
durian auth status              # show auth status for all accounts
durian sync work                # sync an account
durian search "tag:inbox" -l 10 # search emails
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

## License

[MIT](LICENSE)
