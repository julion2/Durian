# Email Sync Setup

colonSend uses `mbsync` for IMAP synchronization and `notmuch` for indexing/searching.

## How It Works

colonSend **automatically** sets up email sync on first launch:

1. Creates `~/.local/bin/colonSend-sync.sh` - wrapper script for mbsync
2. Creates `~/Library/LaunchAgents/com.colonSend.mbsync.plist` - launchd agent
3. Loads the launchd agent

### Why launchd?

mbsync crashes with `SIGSEGV` when launched directly from a macOS app due to `PassCmd` triggering `fork()` in a non-fork-safe environment. Using launchd avoids this by running mbsync in a separate, clean process.

### Sync Behavior

- **Auto-sync:** Based on `auto_fetch_interval` in `config.toml` (default: 60 seconds)
- **Manual sync:** Press `Cmd+R` or the reload button
- **App closed:** No syncing happens (launchd agent has no StartInterval)

The interval is read from your config:
```toml
[settings]
auto_fetch_enabled = true
auto_fetch_interval = 60.0  # seconds
```

## Troubleshooting

### Check if launchd agent is loaded

```bash
launchctl list | grep colonSend
```

You should see: `- 0 com.colonSend.mbsync`

### View sync logs

```bash
cat /tmp/colonSend-mbsync.log
cat /tmp/colonSend-mbsync-error.log
```

### Manually trigger a sync

```bash
launchctl start com.colonSend.mbsync
```

### Reload the launchd agent

```bash
launchctl unload ~/Library/LaunchAgents/com.colonSend.mbsync.plist
launchctl load ~/Library/LaunchAgents/com.colonSend.mbsync.plist
```

### Remove and reinstall

```bash
# Remove
launchctl unload ~/Library/LaunchAgents/com.colonSend.mbsync.plist
rm ~/Library/LaunchAgents/com.colonSend.mbsync.plist
rm ~/.local/bin/colonSend-sync.sh

# Reinstall: Just restart colonSend - it will recreate everything
```

### mbsync still crashes?

Check your `~/.mbsyncrc` for `PassCmd` entries. The wrapper script should handle this, but if you're still having issues:

1. Check if the script exists: `cat ~/.local/bin/colonSend-sync.sh`
2. Check script permissions: `ls -la ~/.local/bin/colonSend-sync.sh` (should be `-rwxr-xr-x`)
3. Try running the script manually: `~/.local/bin/colonSend-sync.sh`

## Files Created

| Path | Description |
|------|-------------|
| `~/.local/bin/colonSend-sync.sh` | Sync script (runs mbsync, writes exit code to completion file) |
| `~/Library/LaunchAgents/com.colonSend.mbsync.plist` | launchd agent (on-demand only, no auto-interval) |
| `/tmp/colonSend-sync-complete` | Completion marker (contains exit code) |
| `/tmp/colonSend-mbsync.log` | stdout from mbsync |
| `/tmp/colonSend-mbsync-error.log` | stderr from mbsync |
