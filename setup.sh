#!/bin/bash
# All-Protocol Tunnel — bootstrap one-liner
# Usage:
#   bash <(curl -sL https://raw.githubusercontent.com/fauzanihanipah/all-protocol/main/setup.sh)
# Or pin a specific branch (default: repo default branch):
#   BRANCH=fix/foo bash <(curl -sL https://raw.githubusercontent.com/fauzanihanipah/all-protocol/main/setup.sh)

set -e

REPO="https://github.com/fauzanihanipah/all-protocol.git"
DEST="/opt/all-protocol"
BRANCH="${BRANCH:-}"

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

# fetch repo (force fresh checkout if branch override set)
if [[ -n "$BRANCH" ]]; then
    echo "[*] Cloning $REPO branch '$BRANCH' to $DEST ..."
    rm -rf "$DEST"
    git clone --depth 1 -b "$BRANCH" "$REPO" "$DEST"
elif [[ -d "$DEST/.git" ]]; then
    echo "[*] Repo sudah ada, pull update..."
    git -C "$DEST" pull --ff-only || { rm -rf "$DEST"; git clone --depth 1 "$REPO" "$DEST"; }
else
    echo "[*] Cloning repo to $DEST ..."
    rm -rf "$DEST"
    git clone --depth 1 "$REPO" "$DEST"
fi

cd "$DEST"
chmod +x install.sh
exec bash install.sh
