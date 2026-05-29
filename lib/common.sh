#!/bin/bash
# Shared helpers for all menus & user scripts

RED=$'\033[1;31m'; GREEN=$'\033[1;32m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[1;34m'; PURPLE=$'\033[1;35m'; CYAN=$'\033[1;36m'; WHITE=$'\033[1;37m'
NC=$'\033[0m'

XRAY_CONFIG="/etc/xray/config.json"
DOMAIN="$(cat /etc/xray/domain 2>/dev/null)"
IP="$(cat /etc/all-protocol.conf 2>/dev/null | awk -F= '/^IP=/{print $2}')"
[[ -z "$IP" ]] && IP="$(curl -s ifconfig.me)"

# Detect stunnel systemd unit name (Debian uses stunnel4, newer uses stunnel)
STUNNEL_SVC=stunnel4
systemctl list-unit-files 2>/dev/null | grep -q '^stunnel4\.service' || STUNNEL_SVC=stunnel

# ---------- UI helpers ----------
# All box rendering shares one width: inner content = 70, full row width = 72.
# We generate the horizontal lines via printf so the count is impossible to
# miscount by eye.
__hline() { local ch="$1" w="$2"; printf -- "$ch%.0s" $(seq 1 "$w"); }
line()       { echo -e "${BLUE}$(__hline = 72)${NC}"; }
sline()      { echo -e "${BLUE}$(__hline - 72)${NC}"; }
header() {
    clear
    line
    printf "${CYAN}%*s${NC}\n" $(( (72 + ${#1}) / 2 )) "$1"
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

# ---------- system status helpers ----------
bbr_status() {
    local cc; cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    [[ "$cc" == "bbr" ]] && echo -e "${GREEN}ENABLED${NC}" || echo -e "${RED}DISABLED${NC}"
}
ipv6_status() {
    local v; v=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
    [[ "$v" == "1" ]] && echo -e "${RED}DISABLED${NC}" || echo -e "${GREEN}ENABLED${NC}"
}
svc_status() {
    systemctl is-active --quiet "$1" \
        && echo -e "${GREEN}ON${NC}" \
        || echo -e "${RED}OFF${NC}"
}

# ---------- 2-column box rendering helpers ----------
# Compute visible width by stripping ANSI escape sequences.
visible_len() {
    echo -n "$1" | sed -E 's/\x1B\[[0-9;]*[mK]//g' | wc -m
}
# Pad string $1 to visible width $2. If the string is *longer* than the
# target width, truncate to (w-1) chars and append '…' so the box border
# never gets pushed and the misalignment we used to have can't recur.
pad() {
    local s="$1" w="$2" vl
    vl=$(visible_len "$s")
    if (( vl > w )); then
        # Strip ANSI for plain truncation (we keep raw bytes for ASCII menus)
        local plain; plain=$(echo -n "$s" | sed -E 's/\x1B\[[0-9;]*[mK]//g')
        s="${plain:0:$((w-1))}…"
        vl=$w
    fi
    local n=$(( w - vl ))
    (( n < 0 )) && n=0
    printf "%s%*s" "$s" "$n" ""
}
# Box characters - outer width 72 columns, inner content 70.
# Layout (single col):  ║ + " " + content(68) + " " + ║   = 1+1+68+1+1 = 72
# Layout (two columns): ║ + " " + L(33) + " " + │ + " " + R(33) + ║ = 72
# Horizontal lines are generated via printf so corner-to-corner is exactly 70.
top_line()    { echo -e "${BLUE}╔$(__hline ═ 70)╗${NC}"; }
mid_line()    { echo -e "${BLUE}╠$(__hline ═ 70)╣${NC}"; }
bot_line()    { echo -e "${BLUE}╚$(__hline ═ 70)╝${NC}"; }
# Single full-width row (68 visible content chars between borders).
single_row() {
    printf "${BLUE}║${NC} %s ${BLUE}║${NC}\n" "$(pad "$1" 68)"
}
# Two-column row: left and right both 33 cols, no trailing space before right ║.
row2() {
    printf "${BLUE}║${NC} %s ${BLUE}│${NC} %s${BLUE}║${NC}\n" \
        "$(pad "$1" 33)" "$(pad "$2" 33)"
}
# Centered title row (white-on-blue look).
title_row() {
    local s="$1" w=68
    local vl; vl=$(visible_len "$s")
    local left=$(( (w - vl) / 2 ))
    local right=$(( w - vl - left ))
    printf "${BLUE}║${NC} %*s${CYAN}%s${NC}%*s ${BLUE}║${NC}\n" "$left" "" "$s" "$right" ""
}
