#!/bin/bash
# Shared helpers for all menus & user scripts

RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
BLUE='\033[1;34m'; PURPLE='\033[1;35m'; CYAN='\033[1;36m'; WHITE='\033[1;37m'
NC='\033[0m'

XRAY_CONFIG="/etc/xray/config.json"
DOMAIN="$(cat /etc/xray/domain 2>/dev/null)"
IP="$(cat /etc/all-protocol.conf 2>/dev/null | awk -F= '/^IP=/{print $2}')"
[[ -z "$IP" ]] && IP="$(curl -s ifconfig.me)"

# ---------- UI helpers ----------
line()       { echo -e "${BLUE}================================================================${NC}"; }
sline()      { echo -e "${BLUE}----------------------------------------------------------------${NC}"; }
header() {
    clear
    line
    printf "${CYAN}%*s${NC}\n" $(( (64 + ${#1}) / 2 )) "$1"
    line
}
press_enter() {
    echo ""
    read -rp " Tekan [Enter] untuk kembali..." x
}
ok()    { echo -e " ${GREEN}[OK]${NC} $1"; }
warn()  { echo -e " ${YELLOW}[!]${NC} $1"; }
fail()  { echo -e " ${RED}[X]${NC} $1"; }

# ---------- Xray helpers ----------
xray_restart() { systemctl restart xray >/dev/null 2>&1; }

# add a client object to a specific inbound (matched by tag)
xray_add_client() {
    local tag="$1" client_json="$2"
    local tmp; tmp="$(mktemp)"
    jq --arg tag "$tag" --argjson c "$client_json" '
        (.inbounds[] | select(.tag == $tag) | .settings.clients) += [$c]
    ' "$XRAY_CONFIG" > "$tmp" && mv "$tmp" "$XRAY_CONFIG"
}

xray_del_client() {
    local tag="$1" key="$2" value="$3"   # key = id|password|email
    local tmp; tmp="$(mktemp)"
    jq --arg tag "$tag" --arg k "$key" --arg v "$value" '
        (.inbounds[] | select(.tag == $tag) | .settings.clients) |=
            map(select(.[$k] != $v))
    ' "$XRAY_CONFIG" > "$tmp" && mv "$tmp" "$XRAY_CONFIG"
}

xray_list_clients() {
    local tag="$1"
    jq -r --arg tag "$tag" '
        .inbounds[] | select(.tag==$tag) | .settings.clients[] |
        [.email, (.id // .password), (.expiry // "-")] | @tsv
    ' "$XRAY_CONFIG"
}

# ---------- random helpers ----------
randpass() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 8; }
genuuid()  { cat /proc/sys/kernel/random/uuid; }
