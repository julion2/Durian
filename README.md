# colonSend

A macOS email client with keyboard shortcuts and auto-refresh capabilities.

## Prerequisites

- [mbsync](https://isync.sourceforge.io/) for IMAP sync
- [notmuch](https://notmuchmail.org/) for email indexing

Install via Homebrew:
```bash
brew install isync notmuch
```

## Email Sync

colonSend automatically sets up email synchronization on first launch:
- Creates `~/.local/bin/colonSend-sync.sh` (sync script)
- Creates launchd agent for mbsync (no StartInterval - on-demand only)
- Syncs based on `auto_fetch_interval` in config.toml (only while app is running)

See [docs/SYNC_SETUP.md](docs/SYNC_SETUP.md) for troubleshooting.

## Configuration

Edit `~/.config/colonSend/config.toml`:

```toml
[settings]
auto_fetch_enabled = true
auto_fetch_interval = 60.0  # seconds
max_emails_to_fetch = 10
notifications_enabled = true
theme = "system"  # "light", "dark", or "system"
load_remote_images = false  # true = load images, false = block tracking pixels

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

Configure shortcuts in `~/.config/colonSend/keymaps.toml`:

```toml
[keymaps]
j = "next_email"
k = "prev_email"
g_g = "first_email"      # vim-style sequence: gg
G = "last_email"
"/" = "search"
Enter = "open_email"
Escape = "close_detail"
r = "reload"
```

Press `Cmd+Shift+K` to reload keymaps.
