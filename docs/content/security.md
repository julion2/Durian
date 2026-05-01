---
title: Security
toc: true
---

{{< callout type="warning" >}}
**Early Alpha — no external security audit.** Durian is a side project. The
threat model, code, and dependencies have not been independently reviewed.
Use at your own risk for non-critical email accounts.
{{< /callout >}}

## Threat model

Durian is a single-user, local-first desktop email client. The implicit
threat model:

- **Trusted:** the local machine running Durian (with its OS keychain and disk encryption), the IMAP/SMTP servers you've configured.
- **Semi-trusted:** the OAuth providers (Google, Microsoft) that issue access tokens.
- **Untrusted:** every other party — including senders of incoming mail and any network in between.

If your local machine is compromised, Durian cannot protect your mail or
credentials — neither can any other locally-running email client.

## Network security

| Connection | Default | Hard requirement |
|---|---|---|
| IMAP | Implicit TLS (port 993) or STARTTLS | TLS, no plaintext |
| SMTP | Implicit TLS (465) or STARTTLS (587, 25) | STARTTLS required for non-implicit-TLS ports — connection fails closed if the server doesn't offer it |
| OAuth flows | HTTPS to provider's authorization endpoint | TLS-validated |
| Tag sync (optional) | HTTP — **run only on a trusted network** (Tailnet, LAN). No TLS, no rate limiting | Off by default |

The SMTP STARTTLS requirement was hardened in
[a recent commit](https://github.com/julion2/durian/commit/560815a):
non-implicit-TLS SMTP ports now fail rather than fall back to plaintext.

## Credential storage

- **OAuth tokens** are stored in **macOS Keychain** (`oauth.SaveToken` →
  `keychain.SetGenericPassword`) or libsecret on Linux. They never appear on
  disk in plaintext.
- **Passwords** for IMAP/SMTP password authentication go through the same
  keychain APIs (`keychain.SetPassword`).
- macOS prompts on first access; see [Disabling the Keychain Access Dialog](docs/auth/password/#disabling-the-keychain-access-dialog) to opt into "always allow Durian" without weakening the keychain itself.

## Data at rest

The local SQLite databases (`email.db`, `contacts.db`) are **not encrypted at
rest** by Durian itself. Mail bodies, attachments, headers, and tags live in
plaintext SQLite files.

**Mitigation:** rely on **FileVault** (macOS) or **LUKS / full-disk
encryption** (Linux). Both encrypt the underlying disk transparently and are
how every macOS user already protects everything else they do.

We do not roll our own encryption. The trade-off is well-understood: FDE +
keychain for credentials covers the realistic threat (lost or stolen device).

## Input handling

- **Incoming HTML** is sanitized through
  [`microcosm-cc/bluemonday`](https://github.com/microcosm-cc/bluemonday)
  before being shown in the Swift WebView. Inline images are loaded from `cid:`
  references via the local server only — no external network fetches happen
  automatically while reading mail (no remote-image tracking).
- **Pkl config** is type-validated at load time. Malformed configs fail loud,
  not silent. `durian validate` runs the same checks ahead of time.
- **Filter rules** can include `exec` hooks that run shell commands. Treat
  `rules.pkl` like you would `~/.zshrc` — anything you put there runs as you.

## Build supply chain

- Go and Swift dependencies are pinned in `cli/go.mod` and Bazel-managed via
  [`MODULE.bazel`](https://github.com/julion2/durian/blob/main/MODULE.bazel).
  Updates are explicit, reviewable commits.
- The Hugo theme (Hextra) is pulled as a Go module (versioned), not vendored.
- Pkl runs as a separate process; we do not embed unreviewed third-party Pkl
  code.

## Reporting a vulnerability

If you find a vulnerability, please **do not** open a public issue.

- Use [GitHub's private security advisory](https://github.com/julion2/durian/security/advisories/new) flow on the repo, or
- Email the maintainer (address visible in the repo metadata).

Expect a best-effort response within a few days. Durian is a side project; we
fix critical issues quickly but cannot promise enterprise SLA times.

## Known limitations

- No external security audit. The first one is welcome.
- No reproducible builds yet (Bazel makes this achievable but it isn't verified end-to-end).
- No code-signing on Linux builds — verify checksums when downloading binaries.
- The optional tag sync server has no TLS or rate limiting; it is intended for
  Tailnet/LAN use, never the public internet.
- Gmail's 7-day OAuth refresh limit (in unverified-app mode) means tokens
  expire faster than for verified apps. Re-authenticate weekly.
