#!/bin/bash
# Install durian-sync server on Linux
# Usage: curl -sSL https://raw.githubusercontent.com/julion2/durian/main/sync/install.sh | bash -s -- --api-key "your-secret"
#
# Options:
#   --api-key KEY    Required. Shared secret for authentication.
#   --port PORT      HTTP port (default: 8724)
#   --db PATH        SQLite database path (default: /var/lib/durian-sync/sync.db)
#   --version VER    Version to install (default: latest)

set -euo pipefail

API_KEY=""
PORT=8724
DB_PATH="/var/lib/durian-sync/sync.db"
VERSION="latest"
INSTALL_DIR="/usr/local/bin"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-key)  API_KEY="$2"; shift 2;;
    --port)     PORT="$2"; shift 2;;
    --db)       DB_PATH="$2"; shift 2;;
    --version)  VERSION="$2"; shift 2;;
    *)          echo "Unknown option: $1"; exit 1;;
  esac
done

if [[ -z "$API_KEY" ]]; then
  echo "Error: --api-key is required"
  echo "Usage: $0 --api-key \"your-secret\""
  exit 1
fi

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  ARCH="amd64";;
  aarch64) ARCH="arm64";;
  *)       echo "Unsupported architecture: $ARCH"; exit 1;;
esac

# Get latest version if not specified
if [[ "$VERSION" == "latest" ]]; then
  VERSION=$(curl -sSL https://api.github.com/repos/julion2/durian/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
  VERSION="${VERSION#v}"
fi

echo "Installing durian-sync v${VERSION} (linux-${ARCH})..."

# Download and install binary
TARBALL="durian-sync-${VERSION}-linux-${ARCH}.tar.gz"
URL="https://github.com/julion2/durian/releases/download/v${VERSION}/${TARBALL}"
curl -sSL "$URL" | tar -xz -C "$INSTALL_DIR"
chmod +x "${INSTALL_DIR}/durian-sync-linux-${ARCH}"
mv "${INSTALL_DIR}/durian-sync-linux-${ARCH}" "${INSTALL_DIR}/durian-sync"

echo "Installed ${INSTALL_DIR}/durian-sync"

# Create data directory
mkdir -p "$(dirname "$DB_PATH")"

# Create systemd service
cat > /etc/systemd/system/durian-sync.service <<EOF
[Unit]
Description=Durian Tag Sync Server
After=network.target

[Service]
ExecStart=${INSTALL_DIR}/durian-sync --api-key "${API_KEY}" --port ${PORT} --db ${DB_PATH}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable durian-sync
systemctl start durian-sync

echo ""
echo "✓ durian-sync installed and running on port ${PORT}"
echo ""
echo "Add to your Durian config (~/.config/durian/config.pkl):"
echo ""
echo "  sync {"
echo "    tag_sync {"
echo "      url = \"http://$(hostname):${PORT}\""
echo "      api_key = \"${API_KEY}\""
echo "    }"
echo "  }"
