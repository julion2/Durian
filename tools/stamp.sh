#!/usr/bin/env bash
# Workspace status command for Bazel stamping.
# Outputs key-value pairs injected into binaries via x_defs.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Version from git tag (e.g. v0.1.1 → 0.1.1), fallback to 0.0.0-dev
VERSION="0.0.0"
if command -v git &>/dev/null; then
    TAG="$(git -C "$REPO_ROOT" describe --tags --abbrev=0 2>/dev/null || true)"
    if [[ -n "$TAG" ]]; then
        VERSION="${TAG#v}"
    fi
fi

# Git commit (short hash)
GIT_COMMIT="unknown"
if command -v git &>/dev/null && git -C "$REPO_ROOT" rev-parse HEAD &>/dev/null; then
    GIT_COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
fi

# Dirty state
GIT_DIRTY=""
if command -v git &>/dev/null && ! git -C "$REPO_ROOT" diff --quiet HEAD -- 2>/dev/null; then
    GIT_DIRTY="true"
fi

# Build number (commit count — monotonically increasing)
BUILD_NUMBER="1"
if command -v git &>/dev/null; then
    BUILD_NUMBER="$(git -C "$REPO_ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
fi

echo "STABLE_VERSION $VERSION"
echo "STABLE_GIT_COMMIT $GIT_COMMIT"
echo "STABLE_GIT_DIRTY $GIT_DIRTY"
echo "STABLE_BUILD_NUMBER $BUILD_NUMBER"
