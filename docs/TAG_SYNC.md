# Tag Sync Server

Sync email tags across multiple machines using a lightweight self-hosted server. Only tag metadata is synced — no email content, no attachments, no bodies.

**Use cases:**
- **Multi-machine:** Keep tags in sync between your Mac and a Linux workstation
- **Backup:** Run the server on a VPS/NAS as a tag backup — even with a single client, all tag changes are durably stored on the server

**Security:** The sync server has minimal auth (API key). Run it in a private network — [Tailscale](https://tailscale.com) (recommended), VPN, or LAN. Do not expose it to the public internet.

## Architecture

```
┌─────────┐        ┌─────────────┐        ┌─────────┐
│  Mac     │◄──────►│  Sync Server │◄──────►│  Linux  │
│  (GUI)   │  HTTP  │  (SQLite)    │  HTTP  │  (CLI)  │
└─────────┘        └─────────────┘        └─────────┘
```

The sync server stores `(message_id, account, tag, action, timestamp)` tuples. Each client pushes local tag changes and pulls remote changes. On pull, only the latest action per `(message_id, account, tag)` is returned.

## Server Setup

### Quick Install (Linux)

```bash
curl -sSL https://raw.githubusercontent.com/julion2/Durian/main/sync/install.sh | sudo bash -s -- --api-key "your-secret"
```

This downloads the latest binary, installs it to `/usr/local/bin`, and sets up a systemd service on port 8724.

### Manual Install

Pre-built binaries for Linux (amd64/arm64) are included in each [GitHub release](https://github.com/julion2/Durian/releases).

```bash
# Download and run
curl -sSL https://github.com/julion2/Durian/releases/latest/download/durian-sync-linux-amd64.tar.gz | tar -xz
./durian-sync-linux-amd64 --api-key "your-secret" --port 8724 --db /var/lib/durian-sync.db
```

Or build from source:
```bash
bazel build //sync:durian-sync --platforms=@rules_go//go/toolchain:linux_amd64
```

### Systemd

```ini
[Unit]
Description=Durian Tag Sync Server
After=network.target

[Service]
ExecStart=/usr/local/bin/durian-sync --api-key "your-secret" --port 8724 --db /var/lib/durian-sync.db
Restart=always

[Install]
WantedBy=multi-user.target
```

## Client Setup

Add to `~/.config/durian/config.toml` on each machine:

```toml
[sync.tag_sync]
url = "http://nas:8724"
api_key = "your-secret"
```

**Important:** Account names must be identical across machines (`name = "Work"` → `AccountIdentifier` = `"work"`). The sync server matches tags by `(message_id, account)`.

### Initial sync

Push all existing tags from your primary machine:

```bash
durian tag-sync push-all
```

On secondary machines, tags are pulled automatically on `durian sync` or `durian serve`.

## How it works

### Push (local → server)

- **GUI (`durian serve`):** Tag changes are pushed immediately (async, best-effort)
- **CLI (`durian tag`):** Changes are written to a local journal (`tag_journal` table). The journal is flushed and pushed on the next `durian sync`

### Pull (server → local)

- **`durian serve`:** Polls the sync server every 30 seconds
- **`durian sync`:** Pulls after IMAP sync completes

Both use a persisted timestamp (`~/.config/durian/tag_sync_at`) for incremental pulls.

## Tailscale

Works great in a Tailnet — no TLS setup, no port forwarding:

```toml
[sync.tag_sync]
url = "http://nas:8724"    # Tailscale hostname or IP
api_key = "your-secret"
```

## API

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/health` | Health check |
| `POST` | `/v1/sync` | Push tag changes |
| `GET` | `/v1/sync?since=<ts>&client_id=<id>` | Pull changes since timestamp |

### Push payload

```json
{
  "client_id": "macbook",
  "changes": [
    {
      "message_id": "abc@example.com",
      "account": "work",
      "tag": "important",
      "action": "add",
      "timestamp": 1234567890
    }
  ]
}
```

### Pull response

```json
{
  "changes": [...],
  "sync_at": 1234567890
}
```

## Limitations

- Tags are matched by `(message_id, account)` — account names must be consistent
- No real-time push to GUI (30s poll interval, or manual Cmd+R)
- `durian tag-sync push-all` pushes all tags as "add" — no removal sync for bulk push
- The server grows over time (append-only journal) — periodically delete old entries if needed
