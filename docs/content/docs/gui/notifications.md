---
title: Notifications
weight: 6
---

Durian posts native macOS notifications when new mail arrives. Click a notification to jump to the thread.

## Enabling

System-level: grant notification permission on first run (System Settings → Notifications → Durian).

App-level toggle in `config.pkl`:

```pkl
settings {
  notifications_enabled = true
}
```

## Per-account override

Disable notifications for specific accounts (e.g. high-volume work mailbox) directly on the account:

```pkl
accounts {
  (C.microsoft365) {
    name = "Work"
    email = "you@company.com"
    alias = "work"
    notifications = false      // silence this one account
  }
}
```

Omit the field to inherit the global setting.

## Filtering noise

Combine notifications with filter rules to silence specific categories. Anything tagged `ephemeral` is treated as low-priority:

```pkl
// rules.pkl
new {
  name = "Bulk notifications"
  match = "header:precedence:bulk OR header:auto-submitted:auto-generated"
  add_tags { "notification"; "ephemeral" }
  remove_tags { "inbox" }
}
```

Mail with `tag:ephemeral` is excluded from system notifications and from the default Inbox query.

## Banner errors (in-app)

Sync failures, OAuth expiry, and SMTP errors surface as toast banners in the bottom-right corner of the main window — see `BannerManager` / `BannerView`. Warnings auto-dismiss after 5 seconds; critical errors stay until clicked.
