---
title: Privacy
toc: true
---

Durian is built around a single principle: **your mail stays on your machine**.
Nothing about how you use the app, the contents of your mail, or even the fact
that you use Durian leaves your device unless you explicitly configure it to.

## What Durian collects

**Nothing.** There is no telemetry, no analytics, no usage stats, no error
reporting service, no auto-updater that phones home. The CLI and the GUI never
contact any Durian-operated server, because there is no Durian-operated server.

## Where your data lives

| Data | Location |
|---|---|
| Email bodies, attachments, threads, tags | `~/.local/share/durian/email.db` (or `$XDG_DATA_HOME/durian/email.db`) — local SQLite |
| Contacts | `~/.local/share/durian/contacts.db` — local SQLite |
| Configuration (accounts, rules, profiles, keymaps, groups) | `~/.config/durian/*.pkl` — plain Pkl files you control |
| OAuth tokens | macOS Keychain or libsecret (Linux), encrypted by the OS |
| IMAP/SMTP passwords | macOS Keychain or libsecret, encrypted by the OS |
| Logs | `~/.local/state/durian/serve.log` — truncated on each `durian serve` start |
| GUI logs | `os_log` (macOS) — same retention as any other app, no upload |

To wipe everything Durian has stored locally:

```bash
rm -rf ~/.local/share/durian ~/.local/state/durian ~/.config/durian
# plus remove keychain entries for "durian-*" service names
```

## Third-party connections

Durian only connects to servers **you configure**:

- **IMAP/SMTP servers** of your email provider (Gmail, Microsoft 365, GMX, your own server, …) — the same connections any email client makes.
- **OAuth providers** (Google, Microsoft) when you run `durian auth login` — only during the login flow, to obtain a token.
- **Optional tag sync server** — only if you set up your own self-hosted server (`sync/` in the source tree) and configure `sync.tag_sync` in `config.pkl`. Disabled by default.

There is no built-in CDN, no Sentry, no Datadog, no Crashlytics, no GA. The
Hextra-powered docs site you are reading right now is statically hosted on
GitHub Pages and serves its content over GitHub's CDN — no tracking from us.

## What gets sent over the network

When Durian syncs:

- IMAP fetches and IDLE notifications from your provider over TLS (port 993 or STARTTLS).
- SMTP sends through your provider over implicit TLS (port 465) or STARTTLS (587).
- OAuth refresh requests, when a token nears expiry.

Nothing else. Mail content, sender lists, and tags never leave the local
SQLite store.

## Telemetry and updates

There is no telemetry. There is no auto-updater. To update Durian you re-run
`brew upgrade durian` or rebuild from source — explicit, manual, opt-in.

## Source code transparency

Durian is open source under MIT. Every line that handles network calls,
storage, or credentials is in
[github.com/julion2/durian](https://github.com/julion2/durian). Search for
`http.`, `imap.`, `smtp.`, or `keychain.` in the codebase to verify exactly
what gets sent where.

## Contact

For privacy questions, [open a GitHub issue](https://github.com/julion2/durian/issues)
or email the maintainer (address in the repo metadata).
