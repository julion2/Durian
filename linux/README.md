# Durian Linux GUI (Early Preview)

> **Read-only early test.** This is an experimental Qt6/QML client to evaluate Linux compatibility and Qt performance for the future. Many features are missing (compose, reply, tag actions, etc.).

Connects to the Durian CLI backend via HTTP API on `localhost:9723`.

## Dependencies

- Qt6 (Core, Gui, Quick, Qml, QuickControls2, WebEngine, Network, Test)
- Bazel

### Fedora / KDE

```bash
sudo dnf install qt6-qtbase-devel qt6-qtdeclarative-devel qt6-qtwebengine-devel
```

### Ubuntu / Debian

```bash
sudo apt install qt6-base-dev qt6-declarative-dev qt6-webengine-dev
```

### Arch

```bash
sudo pacman -S qt6-base qt6-declarative qt6-webengine
```

## Build & Run

```bash
# Find Qt6 root (Fedora: /usr, Homebrew: brew --prefix qt@6)
export QTDIR=/usr

bazel build //linux:durian
bazel run //linux:durian --repo_env=QTDIR=$QTDIR
```

Requires `durian serve` running on `localhost:9723`.

## Tests

```bash
bazel test //linux:all --repo_env=QTDIR=$QTDIR
```

## Project Structure

```
linux/
├── main.cc                 # QML bootstrap
├── BUILD.bazel             # Bazel targets + genrules for rcc/moc
├── qt_repo.bzl             # Qt6 Bazel repository rule
├── models/
│   ├── ThreadModel.h       # QAbstractListModel for email threads
│   ├── ProfileModel.h      # Reads profiles.toml + config.toml
│   ├── NetworkClient.h     # HTTP client (search, threads, attachments)
│   ├── AvatarProvider.h    # Gravatar + Brandfetch async image provider
│   └── IconMap.h           # SF Symbol → Material Symbol mapping
├── data/
│   └── SeedData.h          # Demo data (fallback)
├── qml/
│   ├── Main.qml            # Root window + layout
│   ├── Sidebar.qml         # Profile picker + folder list
│   ├── ThreadList.qml      # Email thread list
│   ├── ThreadRow.qml       # Thread row delegate
│   ├── DetailView.qml      # Threaded message cards + WebEngine
│   ├── ActionBar.qml       # Toolbar
│   ├── KeyHandler.qml      # Vim keybindings
│   ├── SearchPopup.qml     # Raycast-style search
│   ├── Avatar.qml          # Avatar with image + initials fallback
│   └── AvatarHelper.js     # Avatar color/initials logic
├── third_party/
│   └── toml.hpp            # toml++ header-only TOML parser
└── tests/
    ├── icon_map_test.cc
    ├── thread_model_test.cc
    └── profile_model_test.cc
```
