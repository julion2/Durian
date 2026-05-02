---
title: groups.pkl
weight: 4
---

Groups map a role label to a set of email addresses or domain wildcards. Anywhere you can use a query (search, sidebar folders, rules), you can write `group:vip` and have it expand to all matching addresses.

## Skeleton

```pkl
groups {
  ["vip"] {
    description = "Always-surface contacts"
    members { "cofounder@firma.de"; "lead@sequoia.com" }
  }

  ["investor"] {
    members {
      new { "alice@sequoia.com"; "alice.smith@gmail.com" }   // one person, two addresses
      "bob@index.vc"
      "*@fund-xyz.com"                                       // domain wildcard
    }
  }
}
```

## Member shapes

| Shape | Meaning |
|---|---|
| `"alice@x.com"` | Single address |
| `new { "a@x.com"; "a@y.com" }` | Same person with multiple addresses (kept as a unit) |
| `"*@domain.com"` | Any address at that domain |

## Group fields

| Field | Type | Notes |
|---|---|---|
| `description` | `String?` | Free text — only used in `durian group list` output |
| `members` | `Listing` | Mix of strings and nested listings |

## Query syntax

| Query | Meaning |
|---|---|
| `group:vip` | Mail from OR to anyone in the group |
| `group:vip/from` | Only incoming (FROM the group) |
| `group:vip/to` | Only outgoing (TO the group) |

Combine freely:

```text
group:investor AND tag:unread
group:investor/from AND has:attachment:pdf
NOT group:internal           # everything except colleagues
```

## Inspecting groups

```bash
durian group list
durian group members vip
```

The CLI is read-only — edit `groups.pkl` and run `durian validate groups` to check.

## Validate

```bash
durian validate groups
```
