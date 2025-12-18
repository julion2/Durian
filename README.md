<p align="center">
  <img src="docs/logo.png" width="150" />
</p>

<h1 align="center">Durian</h1>

<p align="center">
  A macOS email client for power users. Vim-style navigation, mbsync + notmuch backend.
</p>

---

## Structure
```
gui/    # Swift macOS app
cli/    # Go backend (IPC wrapper for notmuch/mbsync)
specs/  # Feature specs
agents/ # OpenCode agents
```

## Prerequisites
```bash
brew install isync notmuch
```

## Build
```bash
make              # build both
make build-cli    # CLI only
make dev          # CLI + open Xcode
make install      # install CLI to /usr/local/bin
make test         # run tests
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

## Config

`~/.config/durian/config.toml` – see [gui/docs/SYNC_SETUP.md](gui/docs/SYNC_SETUP.md)

