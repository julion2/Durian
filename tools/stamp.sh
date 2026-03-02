#!/usr/bin/env bash
# Workspace status command for Bazel stamping.
# Outputs key-value pairs injected into binaries via x_defs.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Version from VERSION file
VERSION="dev"
if [[ -f "$REPO_ROOT/VERSION" ]]; then
    VERSION="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")"
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

echo "STABLE_VERSION $VERSION"
echo "STABLE_GIT_COMMIT $GIT_COMMIT"
echo "STABLE_GIT_DIRTY $GIT_DIRTY"
