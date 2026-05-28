#!/bin/bash
# fix-services.sh — perbaiki nginx/stunnel/ws/udpgw yang OFF tanpa harus reinstall.
# Jalankan di VPS yang sudah pernah ./install.sh tapi service-nya OFF.
#
# Usage:
#   bash <(curl -sL https://raw.githubusercontent.com/fauzanihanipah/all-protocol/main/fix-services.sh)
#
# Atau lokal:
#   cd /opt/all-protocol && git pull && bash fix-services.sh

set -e
[[ $EUID -ne 0 ]] && { echo "Run as root"; exit 1; }

GREEN=$'\033[1;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[1;31m'; NC=$'\033[0m'
log()  { echo -e " ${GREEN}[*]${NC} $*"; }
warn() { echo -e " ${YELLOW}[!]${NC} $*"; }
fail() { echo -e " ${RED}[X]${NC} $*"; }

REPO=/opt/all-protocol
REPO_URL="https://github.com/fauzanihanipah/all-protocol.git"

# Ensure repo is at latest commit (fall back to fresh re-clone if pull fails)
if [[ -d "$REPO/.git" ]]; then
    log "Pulling latest into $REPO ..."
    if ! git -C "$REPO" pull --ff-only 2>&1 | sed 's/^/    /'; then
        warn "git pull failed, doing fresh re-clone..."
        rm -rf "$REPO"
        git clone --depth 1 "$REPO_URL" "$REPO"
    fi
else
    log "Cloning $REPO ..."
    git clone --depth 1 "$REPO_URL" "$REPO"
fi
cd "$REPO"

# Verify required files exist; if any missing, force re-clone
need_files=(config/nginx.conf config/nginx-vhost.conf config/stunnel.conf
            config/ws.py service/ws.service service/runn.service service/xray.service
            menu/menu lib/common.sh)
missing=0
for f in "${need_files[@]}"; do
    [[ -f "$REPO/$f" ]] || { warn "missing $f"; missing=1; }
done
if (( missing )); then
    warn "Repo lokal tidak lengkap, force re-clone..."
    cd /
    rm -rf "$REPO"
    git clone --depth 1 "$REPO_URL" "$REPO"
    cd "$REPO"
fi

# 1) Pastikan paket nginx-stream terpasang
log "Ensure nginx-stream module..."
if ! nginx -V 2>&1 | grep -q -- '--with-stream' && \
   ! dpkg -l 2>/dev/null | grep -qE 'libnginx-mod-stream|nginx-full|nginx-extras'; then
    apt-get update -y >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y libnginx-mod-stream >/dev/null
    log "libnginx-mod-stream installed"
fi

# 2) Detect stunnel service name
STUNNEL_SVC=stunnel4
systemctl list-unit-files 2>/dev/null | grep -q '^stunnel4\.service' || STUNNEL_SVC=stunnel
log "stunnel service unit: $STUNNEL_SVC"

# 3) Refresh konfig + service files
log "Reinstall config & service files..."
install -m 644 config/nginx.conf       /etc/nginx/nginx.conf
mkdir -p /etc/nginx/conf.d
install -m 644 config/nginx-vhost.conf /etc/nginx/conf.d/all-protocol.conf
DOMAIN=$(cat /etc/xray/domain 2>/dev/null || cat /root/domain 2>/dev/null)
[[ -n "$DOMAIN" ]] && sed -i "s|__DOMAIN__|$DOMAIN|g" /etc/nginx/conf.d/all-protocol.conf || warn "Domain belum tersimpan."

install -m 644 config/stunnel.conf     /etc/stunnel/stunnel.conf
[[ -s /etc/xray/xray.crt && -s /etc/xray/xray.key ]] \
    && cat /etc/xray/xray.key /etc/xray/xray.crt > /etc/stunnel/stunnel.pem \
    || warn "Cert /etc/xray/xray.* hilang"
chmod 640 /etc/stunnel/stunnel.pem 2>/dev/null
chown root:root /etc/stunnel/stunnel.pem 2>/dev/null
sed -i 's|^ENABLED=.*|ENABLED=1|' /etc/default/stunnel4 2>/dev/null || true

install -m 755 config/ws.py            /usr/local/bin/ws-py
install -m 644 service/ws.service      /etc/systemd/system/ws.service
install -m 644 service/runn.service    /etc/systemd/system/runn.service
install -m 644 service/xray.service    /etc/systemd/system/xray.service

# udpgw wrapper
cat > /usr/local/bin/run-udpgw <<'WRAP'
#!/bin/sh
trap 'kill 0' EXIT TERM INT
/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7100 --max-clients 500 --max-connections-for-client 10 &
/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 500 --max-connections-for-client 10 &
wait
WRAP
chmod +x /usr/local/bin/run-udpgw

# 4) Validate nginx config
log "Test nginx config..."
if ! nginx -t 2>&1 | tee /tmp/nginx-test.log; then
    fail "nginx config error - cek /tmp/nginx-test.log"
    exit 1
fi

# 5) Reload + restart all
systemctl daemon-reload
for svc in nginx "$STUNNEL_SVC" ws runn xray dropbear; do
    systemctl enable "$svc" >/dev/null 2>&1
    systemctl restart "$svc" 2>/dev/null
    sleep 1
    if systemctl is-active --quiet "$svc"; then
        log "$svc ${GREEN}ON${NC}"
    else
        fail "$svc still failing — last log:"
        journalctl -u "$svc" -n 6 --no-pager | sed 's/^/    /'
    fi
done

# 6) Reinstall menu/scripts (so $STUNNEL_SVC is picked up everywhere)
install -m 755 menu/menu     /usr/local/sbin/menu
install -m 755 menu/m-ssh    /usr/local/sbin/m-ssh
install -m 755 menu/m-vmess  /usr/local/sbin/m-vmess
install -m 755 menu/m-vless  /usr/local/sbin/m-vless
install -m 755 menu/m-trojan /usr/local/sbin/m-trojan
install -m 755 menu/m-system /usr/local/sbin/m-system
for f in user/*; do install -m 755 "$f" "/usr/local/sbin/$(basename "$f")"; done
install -m 644 lib/common.sh /usr/local/sbin/common.sh

log "Selesai. Jalankan:  menu  -> 5) System -> 12) Diagnose  bila masih ada yg merah."
