---
title: CLI Reference
weight: 3
---

The `durian` CLI is the engine — it handles IMAP sync, SMTP send, SQLite
storage, and exposes an HTTP API for the GUI.

## Commands

| Command | Purpose |
|---|---|
| `durian sync` | Sync mail from IMAP servers |
| `durian send` | Send an email via SMTP |
| `durian search <query>` | Search emails using notmuch query syntax |
| `durian tag <query> <tags>` | Add/remove tags on matching emails |
| `durian show <thread-id>` | Display thread content |
| `durian attachment <id>` | List or download attachments |
| `durian draft save/delete` | Manage drafts on IMAP |
| `durian rules apply` | Apply filter rules to existing mail |
| `durian validate` | Check config files |
| `durian auth` | Manage OAuth tokens / passwords |
| `durian serve` | Start HTTP API server (used by GUI) |

For detailed flags and examples, run `durian <cmd> --help` or read the man pages
(`man durian-<cmd>`).
