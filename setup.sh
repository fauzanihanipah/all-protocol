#!/bin/bash
# All-Protocol Tunnel — bootstrap one-liner
# Usage:
#   bash <(curl -sL https://raw.githubusercontent.com/fauzanihanipah/all-protocol/main/setup.sh)
# or:
#   wget -qO- https://raw.githubusercontent.com/fauzanihanipah/all-protocol/main/setup.sh | bash

set -e

REPO="https://github.com/fauzanihanipah/all-protocol.git"
DEST="/opt/all-protocol"

if [[ $EUID -ne 0 ]]; then
    echo "Script harus dijalankan sebagai root. Gunakan: sudo -i"
    exit 1
fi

echo "=== Bootstrap All-Protocol Tunnel ==="

# install git if missing
if ! command -v git >/dev/null 2>&1; then
    echo "[*] Installing git..."
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y git >/dev/null 2>&1
fi

# fetch repo
if [[ -d "$DEST/.git" ]]; then
    echo "[*] Repo sudah ada, pull update..."
    git -C "$DEST" pull --ff-only
else
    echo "[*] Cloning repo to $DEST ..."
    rm -rf "$DEST"
    git clone --depth 1 "$REPO" "$DEST"
fi

cd "$DEST"
chmod +x install.sh
exec bash install.sh
