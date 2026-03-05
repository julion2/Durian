<p align="center">
  <img src="docs/logo.png" width="150" />
</p>

<h1 align="center">Durian</h1>

<p align="center">
  A macOS email client for power users. Vim-style navigation, IMAP + notmuch backend.
</p>

---

## Structure
```
gui/    # Swift macOS app
cli/    # Go backend (IMAP sync + notmuch)
specs/  # Feature specs
agents/ # OpenCode agents
```

## Prerequisites
```bash
brew install notmuch bazel
```

## Build
```bash
bazel build //...                # build everything
bazel build //cli/...             # CLI only
bazel build //gui:Durian         # GUI only (debug)
bazel build -c opt //gui:Durian  # GUI only (release)
```

### Install CLI
```bash
./cli/install.sh                  # builds & copies to /usr/local/bin/durian
```

### Install GUI
```bash
./gui/install.sh                  # builds & copies to /Applications/Durian.app
```

### Run GUI (dev)
```bash
./gui/run.sh                      # builds debug, installs DurianNightly.app, runs with CLI logs
```

## Test
```bash
bazel test //cli/...              # CLI tests
bazel test //gui/...              # GUI tests
bazel test //...                  # all tests
```

## Logs

```bash
log stream --level debug --predicate 'subsystem == "org.js-lab.durian.nightly"'  # nightly
log stream --level debug --predicate 'subsystem == "org.js-lab.durian"'           # release
log stream --level info  --predicate 'subsystem == "org.js-lab.durian.nightly"'  # info+ only
```

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `j` / `k` | Next / Previous |
| `gg` / `G` | First / Last |
| `Ctrl+d` / `Ctrl+u` | Page down / up |
| `s` | Toggle pin |
| `u` | Toggle read |
| `/` | Search |
| `q` | Close |

Custom keymaps: `~/.config/durian/keymaps.toml`

## CLI

```bash
durian search "tag:inbox" --limit 10
durian show <thread-id>
durian tag "tag:inbox" +archived -unread
durian auth login you@company.com
durian auth status
```

## Config

`~/.config/durian/config.toml`

- [docs/config-example.toml](docs/config-example.toml) – Full config example
- [docs/OAUTH_SETUP.md](docs/OAUTH_SETUP.md) – OAuth setup for Gmail/Microsoft
- [gui/docs/SYNC_SETUP.md](gui/docs/SYNC_SETUP.md) – IMAP/notmuch setup
