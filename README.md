# Durian

A macOS email client with vim-style keyboard shortcuts, powered by mbsync + notmuch.

## Features

- **Vim-style navigation** - j/k, gg/G, Ctrl+d/u
- **Pin & Read toggles** - `s` to pin, `u` to toggle read
- **Auto-sync** - Quick sync (configurable channels) and full sync
- **Multi-account** - Support for multiple email accounts with profiles
- **Context menu** - Right-click for Pin, Read, Delete actions
- **Search** - Global search with `Cmd+/` or `/`

## Prerequisites

- [mbsync](https://isync.sourceforge.io/) for IMAP sync
- [notmuch](https://notmuchmail.org/) for email indexing
- [mailctl](https://github.com/your/mailctl) for notmuch IPC

Install via Homebrew:
```bash
brew install isync notmuch
```

## Email Sync

Durian automatically sets up email synchronization on first launch:
- Creates `~/.local/bin/durian-sync.sh` (sync script)
- Creates launchd agent `com.durian.mbsync.plist`
- Quick sync runs on configurable interval (default: 120s)
- Full sync runs less frequently (default: 2h)

See [docs/SYNC_SETUP.md](docs/SYNC_SETUP.md) for troubleshooting.

## Configuration

Edit `~/.config/durian/config.toml`:

```toml
[settings]
auto_fetch_enabled = true
auto_fetch_interval = 120.0      # Quick sync interval (seconds)
full_sync_interval = 7200.0      # Full sync interval (seconds)
notifications_enabled = true
theme = "system"                 # "light", "dark", or "system"
load_remote_images = false       # Block tracking pixels by default

# Channels for quick sync (subset of accounts for faster sync)
mbsync_channels = ["habric", "gmx"]

[signatures]
work = """
Best regards,
Your Name
"""

[[accounts]]
name = "Personal"
email = "you@example.com"
default_signature = "work"

[accounts.imap]
host = "imap.example.com"
port = 993
ssl = true

[accounts.smtp]
host = "smtp.example.com"
port = 587
ssl = false

[accounts.auth]
username = "you@example.com"
password_keychain = "example-mail-password"
```

### Storing Passwords

Store your password in macOS Keychain:
```bash
security add-generic-password -s "example-mail-password" -a "you@example.com" -w "your-password"
```

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `j` / `k` | Next / Previous email |
| `gg` / `G` | First / Last email |
| `Ctrl+d` / `Ctrl+u` | Page down / up |
| `s` | Toggle pin (star) |
| `u` | Toggle read/unread |
| `/` | Open search |
| `q` / `Escape` | Close detail/search |
| `Cmd+Shift+K` | Reload keymaps |
| `Cmd+Shift+C` | Reload config |

Configure shortcuts in `~/.config/durian/keymaps.toml`:

```toml
[keymaps]
j = "next_email"
k = "prev_email"
g_g = "first_email"      # vim-style sequence: gg
G = "last_email"
s = "toggle_star"
u = "toggle_read"
"/" = "search"
Escape = "close_detail"
```

## License

MIT
