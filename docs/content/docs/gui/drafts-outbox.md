---
title: Drafts & Outbox
weight: 4
---

Durian separates two states: a **draft** is something you're still writing; an **outbox** entry is something you've sent but is waiting in a delay window so you can undo.

## Drafts

### Local autosave

Every keystroke in the compose window is saved to the local SQLite store (`local_drafts` table). If the app crashes, the next launch reopens recovered drafts as compose windows — nothing is lost.

Local drafts are not visible to other devices — they live only on the machine that wrote them.

### Saving to IMAP

`Cmd+S` (or **File → Save Draft**) uploads the draft to the IMAP `Drafts` folder. From there it appears on every device that syncs the same account, including other Durian installs.

Drafts saved to IMAP also remain in the local store until explicitly discarded — closing the compose window doesn't delete them.

## Outbox

### Undo-send window

Hitting `Cmd+Return` doesn't send immediately. It writes the message to the `outbox` table with a `send_after` timestamp a few seconds in the future. During that window:

- A toast banner shows **Sending in 5s — Undo**.
- Clicking **Undo** (or pressing `Cmd+Z` while the banner is up) cancels the send and reopens the compose window with the original content.
- After the timer elapses, the SMTP send happens.

The window is configurable; the GUI defaults to a few seconds.

### Queued while offline

If the network is down (NetworkMonitor detects this), outbox entries stay queued and retry automatically on reconnect. You'll see them under **Outbox** in the sidebar with a status badge.

The CLI also processes the same outbox — `durian send` reads from the same table, so messages queued by the GUI will eventually go out even if the GUI is closed (as long as `durian serve` runs).

## CLI access

```bash
durian search "tag:draft" -l 10        # list IMAP drafts
durian draft delete <message-id>       # delete a draft on IMAP
```

Local-only drafts are not visible to `durian search` — they're in a separate table.
