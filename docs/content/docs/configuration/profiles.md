---
title: profiles.pkl
weight: 2
---

Profiles bundle accounts and define what the sidebar shows. Switch between profiles with `Cmd+1`, `Cmd+2`, etc.

See [GUI → Sidebar & Profiles](../../gui/sidebar-profiles/) for the runtime view.

## Skeleton

```pkl
import "modulepath:/Profiles.pkl" as P

profiles: Listing<P.ProfileConfig> = new {
  new {
    name = "All"; accounts = new { "*" }; default = true
    folders = P.standardFolders
  }
  new {
    name = "Work"; accounts = new { "work" }; color = "#EF4444"
    folders {
      new { name = "Inbox"; icon = "tray"; query = "tag:inbox AND NOT tag:sent" }
      new { name = "Triage" }                                  // section header
      new { name = "To-Do"; icon = "checklist"; query = "tag:todo" }
      for (f in P.systemFolders) { f }
    }
  }
}
```

## Profile fields

| Field | Type | Notes |
|---|---|---|
| `name` | `String` | Shown in profile picker |
| `accounts` | `Listing<String>` | Aliases from `config.pkl`, or `"*"` for all |
| `folders` | `Listing<FolderConfig>` | Sidebar entries |
| `default` | `Boolean` | First profile shown on launch |
| `color` | `String?` | Hex color tinting the active-profile indicator |

## Folder fields

| Field | Type | Notes |
|---|---|---|
| `name` | `String` | Sidebar label |
| `query` | `String?` | Search query (omit for a section header) |
| `icon` | `String?` | SF Symbol name (e.g. `"tray"`, `"checklist"`) |
| `color` | `String?` | Optional folder accent |

Folder queries use the same syntax as `durian search` and the GUI search popup.

## Helpers

`Profiles.pkl` provides:

- `P.standardFolders` — Inbox / Sent / Drafts / Archive / Spam / Trash starter set.
- `P.systemFolders` — Spam / Trash only (handy for splicing into custom layouts).

```pkl
folders {
  new { name = "Custom Inbox"; query = "tag:inbox AND NOT tag:newsletter" }
  // ... your custom entries ...
  for (f in P.systemFolders) { f }
}
```

## Smart views

Anything you can write as a query is fair game:

```pkl
new { name = "Unread VIPs"; icon = "star"; query = "group:vip AND tag:unread" }
new { name = "Has invoice"; icon = "doc"; query = "subject:invoice has:attachment:pdf" }
new { name = "This week"; icon = "calendar"; query = "date:1w.." }
```

Groups (`group:vip`) come from [groups.pkl](../groups/).

## Validate

```bash
durian validate profiles
```
