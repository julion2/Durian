#!/bin/bash
set -euo pipefail

INSTALL_DIR="/usr/local/bin"
BINARY="durian"

# Build first (must run as normal user, not sudo — sudo uses a different bazel cache)
if [ "$(id -u)" -eq 0 ]; then
    echo "Error: Do not run the entire script with sudo."
    echo "Usage: ./cli/install.sh"
    exit 1
fi

echo "Building..."
bazel build //cli/cmd/durian

BAZEL_BIN="$(bazel info bazel-bin)/cli/cmd/durian/durian_/durian"

echo "Installing to $INSTALL_DIR/$BINARY (may ask for password)..."
sudo cp "$BAZEL_BIN" "$INSTALL_DIR/$BINARY"
sudo xattr -dr com.apple.provenance "$INSTALL_DIR/$BINARY" 2>/dev/null || true
sudo codesign --force --sign - "$INSTALL_DIR/$BINARY"
echo "Installed $BINARY to $INSTALL_DIR/$BINARY"
