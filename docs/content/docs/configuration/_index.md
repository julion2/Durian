---
title: Configuration
weight: 2
---

Durian is configured entirely through Pkl files in `~/.config/durian/`:

| File | Purpose |
|---|---|
| `config.pkl` | Accounts (IMAP/SMTP/OAuth), sync settings |
| `profiles.pkl` | Folder bindings (gi/gs/ga key shortcuts) |
| `rules.pkl` | Filter rules: tag/move/forward on incoming mail |
| `groups.pkl` | Contact groups (e.g. `group:investor` in queries) |
| `keymaps.pkl` | Custom keyboard bindings |

Run `durian validate` to check syntax and types of all config files.
