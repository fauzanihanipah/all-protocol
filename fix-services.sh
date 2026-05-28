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

# 1) Pastikan modul stream nginx tersedia & ter-load
log "Ensure nginx stream module..."
need_stream_pkg=1
# Kalau nginx di-compile dengan --with-stream (statik), tidak perlu paket dinamis.
if nginx -V 2>&1 | grep -q -- '--with-stream'; then
    need_stream_pkg=0
fi
if (( need_stream_pkg )); then
    apt-get update -y >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y libnginx-mod-stream >/dev/null 2>&1 \
        && log "libnginx-mod-stream installed/up-to-date" \
        || warn "Gagal pasang libnginx-mod-stream — coba 'apt-get install libnginx-mod-stream' manual"
fi

# Pastikan modul ter-enable (symlink ada di /etc/nginx/modules-enabled/)
if [[ -d /etc/nginx/modules-available ]] && \
   ls /etc/nginx/modules-enabled/ 2>/dev/null | grep -q 'mod-stream' ; then
    :
elif [[ -f /usr/share/nginx/modules-available/mod-stream.conf ]]; then
    mkdir -p /etc/nginx/modules-enabled
    ln -sf /usr/share/nginx/modules-available/mod-stream.conf \
           /etc/nginx/modules-enabled/50-mod-stream.conf
    log "Linked mod-stream into modules-enabled"
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
if [[ -n "$DOMAIN" ]]; then
    DOMAIN_RE=$(echo "$DOMAIN" | sed 's|\.|\\.|g')
    sed -i "s|__DOMAIN__|$DOMAIN|g; s|__DOMAIN_RE__|$DOMAIN_RE|g" /etc/nginx/nginx.conf
    sed -i "s|__DOMAIN__|$DOMAIN|g" /etc/nginx/conf.d/all-protocol.conf
else
    warn "Domain belum tersimpan - SNI multiplex 443 mungkin nge-route semua ke stunnel."
fi

install -m 644 config/stunnel.conf     /etc/stunnel/stunnel.conf
[[ -s /etc/xray/xray.crt && -s /etc/xray/xray.key ]] \
    && cat /etc/xray/xray.key /etc/xray/xray.crt > /etc/stunnel/stunnel.pem \
    || warn "Cert /etc/xray/xray.* hilang - SSH-SSL tidak akan jalan!"
chmod 644 /etc/stunnel/stunnel.pem 2>/dev/null
chown root:root /etc/stunnel/stunnel.pem 2>/dev/null
sed -i 's|^ENABLED=.*|ENABLED=1|' /etc/default/stunnel4 2>/dev/null || true

# Buka firewall untuk SSH-SSL (443 mux + 777 langsung) bila ufw aktif
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q active; then
    for p in 22 80 443 109 143 777 7100 7300; do
        ufw allow $p/tcp >/dev/null 2>&1
    done
fi

install -m 755 config/ws.py            /usr/local/bin/ws-py
install -m 644 service/ws.service      /etc/systemd/system/ws.service
install -m 644 service/runn.service    /etc/systemd/system/runn.service
install -m 644 service/xray.service    /etc/systemd/system/xray.service

# Pastikan /bin/false ter-listed di /etc/shells supaya useradd -s /bin/false
# tidak ditolak Dropbear/OpenSSH saat login (PAM check_shells).
grep -qx '/bin/false' /etc/shells 2>/dev/null || echo '/bin/false' >> /etc/shells
grep -qx '/usr/sbin/nologin' /etc/shells 2>/dev/null || echo '/usr/sbin/nologin' >> /etc/shells

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
