# Durian Linux GUI Spike (Qt6)

## Dependencies

- Qt6
- Bazel

Set one of these env vars to your Qt6 root:

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
