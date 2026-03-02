#!/bin/bash
set -euo pipefail

APP_NAME="Durian"
INSTALL_DIR="/Applications"

# Build first (must run as normal user, not sudo — sudo uses a different bazel cache)
if [ "$(id -u)" -eq 0 ]; then
    echo "Error: Do not run the entire script with sudo."
    echo "Usage: ./gui/install.sh"
    exit 1
fi

echo "Building..."
bazel build -c opt //gui:Durian

# Bazel produces a zip containing the .app bundle
BAZEL_ZIP="$(bazel cquery //gui:Durian -c opt --output=files 2>/dev/null)"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "Extracting..."
unzip -q "$BAZEL_ZIP" -d "$TMPDIR"

echo "Installing to $INSTALL_DIR/$APP_NAME.app (may ask for password)..."
if [ -d "$INSTALL_DIR/$APP_NAME.app" ]; then
    sudo rm -rf "$INSTALL_DIR/$APP_NAME.app"
fi
sudo cp -R "$TMPDIR/$APP_NAME.app" "$INSTALL_DIR/$APP_NAME.app"

echo "Installed $APP_NAME.app to $INSTALL_DIR/"
