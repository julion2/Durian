---
title: GUI
weight: 2
sidebar:
  open: true
---

A native macOS app, written in SwiftUI. A thin layer over the `durian` CLI — the GUI never touches the database directly, every action is an HTTP call to `durian serve` running as a child process.

If you live in the terminal, the CLI alone is enough. The GUI is for everything that's nicer with a window: reading threads, composing rich-text mail, dragging attachments, glancing at the sidebar.

{{< cards >}}
  {{< card link="compose" title="Compose" subtitle="HTML editor with vim mode, contact autocomplete, signatures." >}}
  {{< card link="sidebar-profiles" title="Sidebar & Profiles" subtitle="Custom folders, smart views, per-profile accent colors." >}}
  {{< card link="search" title="Search" subtitle="Notmuch-style query syntax with a live popup." >}}
  {{< card link="drafts-outbox" title="Drafts & Outbox" subtitle="Local autosave, undo-send window, queued sending." >}}
  {{< card link="attachments" title="Attachments" subtitle="QuickLook preview, cached prefetch on thread open." >}}
  {{< card link="notifications" title="Notifications" subtitle="System notifications on new mail, per-account overrides." >}}
  {{< card link="keymaps" title="Keymaps" subtitle="Vim bindings throughout, configurable in keymaps.pkl." >}}
{{< /cards >}}
