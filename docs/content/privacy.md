---
title: Privacy
toc: false
---

Durian is local-first. Your mail and metadata stay on your device.

## No telemetry

No analytics, no usage stats, no error reporting, no auto-updater. The CLI and GUI never contact a Durian-operated server, because none exists.

## Where your data lives

| Data | Location |
|---|---|
| Mail, threads, tags, attachments | `~/.local/share/durian/email.db` |
| Contacts | `~/.local/share/durian/contacts.db` |
| Configuration | `~/.config/durian/*.pkl` |
| OAuth tokens, IMAP/SMTP passwords | OS keychain |

## Network connections

Durian only connects to servers **you configure**:

- Your IMAP/SMTP provider over TLS.
- OAuth issuers (Google, Microsoft) — only during `durian auth login` and token refresh.
- An optional self-hosted tag sync server, off by default.

There is no Durian-operated CDN, telemetry endpoint, or update server.

## Wipe everything

```bash
rm -rf ~/.local/share/durian ~/.local/state/durian ~/.config/durian
```

Plus delete keychain entries whose service starts with `durian-`.
