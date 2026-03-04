#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="DurianNightly"

echo "Building..."
bazel build //gui:Durian

ZIP="$(bazel cquery //gui:Durian --output=files 2>/dev/null)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
unzip -qo "$ZIP" -d "$TMPDIR"

pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
sleep 0.5

rm -rf "/Applications/$APP_NAME.app"
cp -R "$TMPDIR/$APP_NAME.app" "/Applications/$APP_NAME.app"

echo "Running $APP_NAME..."
exec "/Applications/$APP_NAME.app/Contents/MacOS/$APP_NAME"
