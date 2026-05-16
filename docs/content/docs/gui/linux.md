---
title: Linux (Qt MVP)
weight: 99
---

There is an experimental Qt6/QML client in `linux/` that talks to the same
`durian serve` HTTP API as the macOS GUI. It is **read-only** today —
search, sidebar, thread view, attachment download. No compose, no reply,
no tag actions.

The macOS GUI is the supported client. The Linux build exists to evaluate
Qt as a long-term Linux story and to keep the CLI honest about its API
contract.

## Status

| | macOS (SwiftUI) | Linux (Qt6) |
|---|---|---|
| Read mail | ✅ | ✅ |
| Search | ✅ | ✅ |
| Profiles / folders | ✅ | ✅ |
| Attachments (download) | ✅ | ✅ |
| Compose / reply | ✅ | ❌ |
| Tag actions | ✅ | ❌ |
| Auto-launches `durian serve` | ✅ | ❌ (manual) |
| Bearer-token auth handshake | ✅ | ❌ (uses `--no-auth`) |

## Build

Install Qt6 plus the `pkl` CLI (used at runtime to read `profiles.pkl` /
`config.pkl`):

```bash
# Fedora / KDE
sudo dnf install qt6-qtbase-devel qt6-qtdeclarative-devel qt6-qtwebengine-devel
brew install pkl  # or your distro's pkl package

# Ubuntu / Debian
sudo apt install qt6-base-dev qt6-declarative-dev qt6-webengine-dev

# Arch
sudo pacman -S qt6-base qt6-declarative qt6-webengine
```

Then build with Bazel:

```bash
export QTDIR=/usr           # Fedora/Debian
# export QTDIR=$(brew --prefix qt@6)   # macOS / Linuxbrew
bazel build //linux:durian --repo_env=QTDIR=$QTDIR
```

## Run

The Linux GUI does **not** auto-start `durian serve` and does not yet
implement the bearer-token handshake the macOS GUI uses. You need to start
the server yourself, with `--no-auth`:

```bash
durian serve --no-auth
```

Then in another shell:

```bash
bazel run //linux:durian --repo_env=QTDIR=$QTDIR
```

Loopback-only access is still enforced. See the [CLI serve
docs](../cli/#auth--bind) for the trade-off.

## Roadmap

If the Linux client graduates beyond MVP, the obvious next steps are:

1. Auto-spawn `durian serve` and capture the `READY` line, like the macOS
   GUI does (drops the `--no-auth` requirement).
2. Compose / reply via the existing `/outbox` API.
3. Tag actions and folder moves via `/threads/{id}/tags`.

The architecture already supports all three — both clients hit the same
HTTP API; only the Qt-side wiring is missing.
