#!/bin/bash
set -euo pipefail

INSTALL_DIR="/usr/local/bin"
BINARY="durian"

# Find the bazel-built binary
BAZEL_BIN="$(bazel info bazel-bin 2>/dev/null)/cli/cmd/durian/durian_/durian"

if [ ! -f "$BAZEL_BIN" ]; then
    echo "Binary not found. Building..."
    bazel build //cli/cmd/durian
    BAZEL_BIN="$(bazel info bazel-bin)/cli/cmd/durian/durian_/durian"
fi

cp "$BAZEL_BIN" "$INSTALL_DIR/$BINARY"
echo "Installed $BINARY to $INSTALL_DIR/$BINARY"
