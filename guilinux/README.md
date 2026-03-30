# Durian Linux GUI Spike (Qt6)

Minimal Qt6 Widgets UI for a Linux-only spike. No releases, build from source only.

## Requirements

- Qt6 installed locally
- Bazel

Set one of these env vars to your Qt6 root (the folder that contains `include/` and `lib/`):

```bash
export QTDIR=/opt/Qt/6.6.3/gcc_64
# or
export QT_HOME=/opt/Qt/6.6.3/gcc_64
```

## Build

```bash
bazel build //guilinux:guilinux
```

## Run

```bash
bazel run //guilinux:guilinux
```

## Scope

- Sidebar thread list
- Detail view (subject, sender, preview)
- Static data only

## Next (if we continue)

- Wire to CLI HTTP API (`localhost:9723`)
- Search input + refresh
- Thread list styling and virtualized model
