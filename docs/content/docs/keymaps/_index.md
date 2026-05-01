---
title: Keymaps
weight: 4
sidebar:
  open: true
---

Durian uses vim-style key bindings throughout the GUI. The key sequence engine supports chords (e.g. `gi`, `gs`, `ga` for go-to-inbox/sent/archive).

## Email list — default bindings

| Key | Action |
|---|---|
| `j` / `k` | Next / previous email |
| `gi` | Go to inbox |
| `gs` | Go to sent |
| `gd` | Go to drafts |
| `ga` | Go to archive |
| `r` | Reply |
| `f` | Forward |
| `t` | Tag picker |
| `/` | Search |
| `c` | Compose |
| `Enter` | Open thread |

Customize via `~/.config/durian/keymaps.pkl`. Run `durian validate keymaps` to verify your overrides.

## Compose editor

The compose editor has its own modal vim mode. See [Vim compose](vim-compose/) for the full reference.
