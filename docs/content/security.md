---
title: Security
toc: false
---

{{< callout type="warning" >}}
**Early Alpha — no external security audit.** Use at your own risk for non-critical mail.
{{< /callout >}}

## Network

- **IMAP**: TLS-only — implicit TLS (993) or STARTTLS, no plaintext fallback.
- **SMTP**: implicit TLS (465) or STARTTLS (587/25); STARTTLS is required, the connection fails closed if the server doesn't offer it.
- **OAuth**: HTTPS to the provider's authorization endpoint.
- **Tag sync** (optional): runs over plain HTTP. Use only on a trusted network (Tailnet, LAN) — never the public internet.

## Credentials

OAuth tokens and passwords are stored in **macOS Keychain** or **libsecret** (Linux), never on disk in plaintext.

## Data at rest

The local SQLite databases are **not encrypted by Durian**. Rely on **FileVault** (macOS) or full-disk encryption (Linux).

## Reporting a vulnerability

Use [GitHub's private security advisory](https://github.com/julion2/durian/security/advisories/new) flow. Please do not open a public issue.
