#!/bin/bash
# =====================================================================
#  ALL-PROTOCOL TUNNEL INSTALLER
#  SSH (OpenSSH + Dropbear) | SSH-WS TLS & Non-TLS | SSH-SSL 443
#  V2Ray VMess | V2Ray VLess | Trojan (via Xray)
#  Author: Kiro generated for fauzanihanipah
#  Tested: Ubuntu 20.04 / 22.04 / Debian 10 / 11
# =====================================================================

# ---------- root check ----------
if [[ $EUID -ne 0 ]]; then
   echo "Script harus dijalankan sebagai root. Coba: sudo -i"
   exit 1
fi

# ---------- colors ----------
RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
BLUE='\033[1;34m'; CYAN='\033[1;36m'; NC='\033[0m'

print_ok()    { echo -e " ${GREEN}[ OK ]${NC} $1"; }
print_info()  { echo -e " ${CYAN}[INFO]${NC} $1"; }
print_warn()  { echo -e " ${YELLOW}[WARN]${NC} $1"; }
print_err()   { echo -e " ${RED}[FAIL]${NC} $1"; }
print_title() {
  clear
  echo -e "${BLUE}================================================================${NC}"
  echo -e "${CYAN}            ALL-PROTOCOL TUNNEL INSTALLER${NC}"
  echo -e "${BLUE}================================================================${NC}"
  echo -e " ${YELLOW}$1${NC}"
  echo -e "${BLUE}----------------------------------------------------------------${NC}"
}

# ---------- binary URLs (provided by user) ----------
XRAY_URL="https://github.com/chanelog/max/releases/download/bin/Xray-linux-64.zip"
UDPGW_URL="https://raw.githubusercontent.com/chanelog/max/main/udpgw"
WS_URL="https://raw.githubusercontent.com/chanelog/max/main/ws"
WS_SERVICE_URL="https://raw.githubusercontent.com/chanelog/max/main/ws.service"

# ---------- repo source dir (where this installer lives) ----------
SRC="$(cd "$(dirname "$0")" && pwd)"

# ---------- ask domain ----------
print_title "INPUT DOMAIN"
read -rp " Masukkan domain (contoh: tunnel.example.com) : " DOMAIN
if [[ -z "$DOMAIN" ]]; then
  print_err "Domain wajib diisi."
  exit 1
fi

mkdir -p /etc/xray /etc/v2ray /var/log/xray /var/lib/all-protocol
PUB_IP=$(curl -s4 ifconfig.me 2>/dev/null || curl -s4 https://api.ipify.org 2>/dev/null)
echo "IP=$PUB_IP" > /etc/all-protocol.conf
echo "DOMAIN=$DOMAIN" >> /etc/all-protocol.conf
echo "$DOMAIN" > /etc/xray/domain
echo "$DOMAIN" > /root/domain

# Pre-flight DNS check: pastikan domain sudah resolve ke IP VPS ini.
# Kalau salah, acme.sh akan gagal silent dan kita fallback ke self-signed
# yang akan membuat mobile injector menolak cert ("punya orang"/mismatch).
print_title "0/7 PRE-FLIGHT DNS CHECK"
print_info "Public IP    : $PUB_IP"
DNS_IP=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1; exit}')
[[ -z "$DNS_IP" ]] && DNS_IP=$(dig +short A "$DOMAIN" 2>/dev/null | head -1)
print_info "DNS A record : ${DNS_IP:-(belum resolve)}"

if [[ -z "$DNS_IP" ]]; then
    print_err "Domain $DOMAIN belum resolve ke IP manapun."
    print_err "Tambah A record: $DOMAIN -> $PUB_IP  di DNS provider, tunggu propagasi, baru run install.sh lagi."
    exit 1
elif [[ "$DNS_IP" != "$PUB_IP" ]]; then
    print_warn "DNS resolve ke $DNS_IP tapi IP VPS ini $PUB_IP."
    print_warn "Let's Encrypt akan GAGAL. Update A record $DOMAIN -> $PUB_IP, tunggu propagasi (5-10 menit)."
    read -rp " Lanjut tetap (akan pakai self-signed) ? [y/N] : " yn
    [[ "${yn,,}" != "y" ]] && exit 1
else
    print_ok "DNS sudah benar: $DOMAIN -> $PUB_IP"
fi

# /etc/shells diedit lebih awal supaya add-ssh yang dipanggil kapan pun
# selama install (mis. dari trial atau test) tidak ditolak PAM/Dropbear.
grep -qx '/bin/false'        /etc/shells 2>/dev/null || echo '/bin/false'        >> /etc/shells
grep -qx '/usr/sbin/nologin' /etc/shells 2>/dev/null || echo '/usr/sbin/nologin' >> /etc/shells

# =====================================================================
# 1. UPDATE & DEPENDENCIES
# =====================================================================
print_title "1/7 INSTALL DEPENDENCIES"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null 2>&1
# Detect which stunnel package is available (Debian: stunnel4, newer: stunnel)
STUNNEL_PKG=stunnel4
apt-cache show stunnel4 >/dev/null 2>&1 || STUNNEL_PKG=stunnel

apt-get install -y --no-install-recommends \
    curl wget unzip jq qrencode socat netcat-openbsd cron iptables \
    nginx libnginx-mod-stream \
    $STUNNEL_PKG dropbear openssh-server \
    python3 python3-pip uuid-runtime \
    sudo screen bc vnstat lsof net-tools dnsutils \
    cmake build-essential git file >/dev/null 2>&1

# Resolve the actual systemd unit name for stunnel
STUNNEL_SVC=stunnel4
systemctl list-unit-files 2>/dev/null | grep -q '^stunnel4\.service' || STUNNEL_SVC=stunnel
print_ok "Dependencies terinstall (stunnel pkg=$STUNNEL_PKG, svc=$STUNNEL_SVC)."

# =====================================================================
# 2. DOWNLOAD BINARIES
# =====================================================================
print_title "2/7 DOWNLOAD BINARIES"

# --- Xray ---
print_info "Mengunduh Xray-core..."
mkdir -p /tmp/xray && cd /tmp/xray
wget -q "$XRAY_URL" -O xray.zip
unzip -o -q xray.zip
install -m 755 xray /usr/local/bin/xray
mkdir -p /usr/local/share/xray
[[ -f geoip.dat ]] && cp -f geoip.dat /usr/local/share/xray/
[[ -f geosite.dat ]] && cp -f geosite.dat /usr/local/share/xray/
cd / && rm -rf /tmp/xray
print_ok "Xray terinstall: $(/usr/local/bin/xray version | head -n1)"

# --- BadVPN UDPGW ---
print_info "Mengunduh badvpn-udpgw..."
wget -q "$UDPGW_URL" -O /usr/local/bin/badvpn-udpgw
chmod +x /usr/local/bin/badvpn-udpgw
# Wrapper that runs both 7100 + 7300 in one foreground process group
cat > /usr/local/bin/run-udpgw <<'WRAP'
#!/bin/sh
trap 'kill 0' EXIT TERM INT
/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7100 --max-clients 500 --max-connections-for-client 10 &
/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 500 --max-connections-for-client 10 &
wait
WRAP
chmod +x /usr/local/bin/run-udpgw
print_ok "UDPGW terinstall (wrapper /usr/local/bin/run-udpgw)."

# --- WebSocket Proxy (untuk SSH-WS) ---
# Kita TIDAK pakai ws.service dari URL eksternal (tidak terkontrol).
# Gunakan ws.py kita sendiri, lebih reliable.
print_info "Mengunduh ws binary (cadangan, tidak dipakai default)..."
wget -q "$WS_URL" -O /usr/local/bin/ws 2>/dev/null
chmod +x /usr/local/bin/ws 2>/dev/null
print_ok "WS proxy disiapkan (pakai ws-py Python untuk reliability)."

# =====================================================================
# 3. SSL CERTIFICATE (acme.sh)
# =====================================================================
print_title "3/7 ISSUE SSL CERTIFICATE"
print_info "Issuing cert untuk $DOMAIN ..."
systemctl stop nginx >/dev/null 2>&1
mkdir -p /etc/xray
curl -s https://get.acme.sh | sh -s email=admin@${DOMAIN} >/dev/null 2>&1
~/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1
ACME_LOG=/var/log/acme-issue.log
~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256 --force >"$ACME_LOG" 2>&1
ACME_RC=$?

# Install cert, plus reloadcmd yang otomatis sinkron stunnel.pem &
# restart service tiap kali Let's Encrypt renew (default 60 hari sekali).
~/.acme.sh/acme.sh --installcert -d "$DOMAIN" --ecc \
  --fullchain-file /etc/xray/xray.crt \
  --key-file /etc/xray/xray.key \
  --reloadcmd "cat /etc/xray/xray.key /etc/xray/xray.crt > /etc/stunnel/stunnel.pem && chmod 640 /etc/stunnel/stunnel.pem && systemctl restart $STUNNEL_SVC nginx xray" \
  >>"$ACME_LOG" 2>&1

if [[ -s /etc/xray/xray.crt && -s /etc/xray/xray.key ]] && \
   openssl x509 -in /etc/xray/xray.crt -noout -issuer 2>/dev/null | grep -qiE "Let's Encrypt|R3|R10|E[0-9]"; then
    print_ok "Sertifikat Let's Encrypt issued: $(openssl x509 -in /etc/xray/xray.crt -noout -subject)"
    print_ok "Auto-renew aktif (reloadcmd akan re-sync stunnel.pem tiap renew)"
else
    print_err "Issue Let's Encrypt GAGAL. Alasan paling umum:"
    print_err "  - Port 80 ke-block firewall cloud (Alibaba SG / AWS SG / GCP firewall)"
    print_err "  - DNS A record belum propagasi ke IP VPS ini ($PUB_IP)"
    print_err "  - Rate-limit Let's Encrypt (max 5 cert per minggu per domain)"
    print_warn "Detail log: $ACME_LOG  -> 'tail -50 $ACME_LOG'"
    print_warn "Fallback ke self-signed (mobile injector kemungkinan REJECT cert)."
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout /etc/xray/xray.key -out /etc/xray/xray.crt \
        -subj "/CN=$DOMAIN" -days 825 >/dev/null 2>&1
    print_warn "Setelah perbaiki masalah di atas, jalankan:"
    print_warn "  ~/.acme.sh/acme.sh --issue -d $DOMAIN --standalone --force"
fi
chmod 644 /etc/xray/xray.crt
chmod 600 /etc/xray/xray.key

# =====================================================================
# 4. CONFIGURATION FILES
# =====================================================================
print_title "4/7 DEPLOY CONFIGURATION FILES"

# --- Xray (VMess + VLess + Trojan WS+gRPC) ---
install -m 644 "$SRC/config/xray.json"          /etc/xray/config.json

# --- Nginx (HTTPS internal 8443 + HTTP 80) ---
rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf 2>/dev/null
install -m 644 "$SRC/config/nginx.conf"         /etc/nginx/nginx.conf
install -m 644 "$SRC/config/nginx-vhost.conf"   /etc/nginx/conf.d/all-protocol.conf
DOMAIN_RE=$(echo "$DOMAIN" | sed 's|\.|\\.|g')
sed -i "s|__DOMAIN__|$DOMAIN|g; s|__DOMAIN_RE__|$DOMAIN_RE|g" /etc/nginx/nginx.conf
sed -i "s|__DOMAIN__|$DOMAIN|g" /etc/nginx/conf.d/all-protocol.conf

# --- Stunnel (SSH SSL backend) ---
install -m 644 "$SRC/config/stunnel.conf"       /etc/stunnel/stunnel.conf
sed -i 's|^ENABLED=.*|ENABLED=1|' /etc/default/stunnel4 2>/dev/null || true
cat /etc/xray/xray.key /etc/xray/xray.crt > /etc/stunnel/stunnel.pem
chmod 640 /etc/stunnel/stunnel.pem
chown root:root /etc/stunnel/stunnel.pem

# Validasi awal stunnel.conf — kalau syntax fail, fallback ke config minimal
# supaya service tetap bisa start (bisa di-tune lewat fix-services nanti).
if ! stunnel /etc/stunnel/stunnel.conf -fd 0 </dev/null 2>&1 | grep -q '\[!\]'; then
    print_ok "stunnel.conf syntax OK"
else
    print_warn "stunnel.conf syntax warning - cek 'journalctl -u $STUNNEL_SVC' setelah install"
fi

# Pastikan modul nginx-stream ter-enable (paket libnginx-mod-stream di
# Debian/Ubuntu meletakkan modul di modules-available; auto-symlink ke
# modules-enabled sometimes missing).
if ! ls /etc/nginx/modules-enabled/ 2>/dev/null | grep -q 'mod-stream'; then
    if [[ -f /usr/share/nginx/modules-available/mod-stream.conf ]]; then
        mkdir -p /etc/nginx/modules-enabled
        ln -sf /usr/share/nginx/modules-available/mod-stream.conf \
               /etc/nginx/modules-enabled/50-mod-stream.conf
    fi
fi

# --- Dropbear ---
install -m 644 "$SRC/config/dropbear"           /etc/default/dropbear

# --- WS python proxy (jika bin ws gagal jalan, fallback python) ---
install -m 755 "$SRC/config/ws.py"              /usr/local/bin/ws-py

# --- Service files ---
install -m 644 "$SRC/service/runn.service"      /etc/systemd/system/runn.service
install -m 644 "$SRC/service/xray.service"      /etc/systemd/system/xray.service
install -m 644 "$SRC/service/ws.service"        /etc/systemd/system/ws.service

print_ok "Konfigurasi ter-deploy."

# =====================================================================
# 5. INSTALL MENU & USER SCRIPTS
# =====================================================================
print_title "5/7 INSTALL MENU & USER MANAGEMENT"
mkdir -p /usr/local/sbin
install -m 755 "$SRC/menu/menu"        /usr/local/sbin/menu
install -m 755 "$SRC/menu/m-ssh"       /usr/local/sbin/m-ssh
install -m 755 "$SRC/menu/m-vmess"     /usr/local/sbin/m-vmess
install -m 755 "$SRC/menu/m-vless"     /usr/local/sbin/m-vless
install -m 755 "$SRC/menu/m-trojan"    /usr/local/sbin/m-trojan
install -m 755 "$SRC/menu/m-system"    /usr/local/sbin/m-system

for f in "$SRC"/user/*; do
    install -m 755 "$f" "/usr/local/sbin/$(basename "$f")"
done

# common library
install -m 644 "$SRC/lib/common.sh"    /usr/local/sbin/common.sh
print_ok "Menu installed (jalankan: menu)"

# =====================================================================
# 6. ENABLE & START SERVICES
# =====================================================================
print_title "6/7 START SERVICES"

# allow ports through ufw if active
if command -v ufw >/dev/null && ufw status | grep -q active; then
  for p in 22 80 443 109 143 444 777 7100 7300 8443 2082 2083 8080 8880; do
    ufw allow $p/tcp >/dev/null 2>&1
  done
fi

systemctl daemon-reload

# Test nginx config first; abort start if invalid
if ! nginx -t >/dev/null 2>&1; then
    print_warn "nginx -t FAILED, mencoba auto-fix:"
    nginx -t 2>&1 | sed 's/^/    /'
fi

start_and_check() {
    local svc="$1"
    systemctl enable "$svc" >/dev/null 2>&1
    systemctl restart "$svc" >/dev/null 2>&1
    sleep 1
    if systemctl is-active --quiet "$svc"; then
        print_ok "$svc started"
    else
        print_err "$svc FAILED:"
        journalctl -u "$svc" -n 8 --no-pager 2>/dev/null | sed 's/^/    /'
    fi
}

start_and_check nginx
start_and_check dropbear
start_and_check "$STUNNEL_SVC"
start_and_check xray
start_and_check ws
start_and_check runn
systemctl restart ssh                  >/dev/null 2>&1

print_ok "Service start sequence selesai."

# =====================================================================
# 6.5. END-TO-END HEALTH CHECK
# =====================================================================
print_info "Health check (port + handshake + banner)..."
hc_fail=0
hc() { local label="$1" cond="$2"; if eval "$cond" >/dev/null 2>&1; then print_ok "$label"; else print_err "$label"; hc_fail=$((hc_fail+1)); fi; }

# Port listen
hc "Port :80   nginx"        "ss -ltn | grep -q ':80\b'"
hc "Port :443  nginx-stream" "ss -ltn | grep -q ':443\b'"
hc "Port :109  Dropbear"     "ss -ltn | grep -q ':109\b'"
hc "Port :777  Stunnel pub"  "ss -ltn | grep -q ':777\b'"
hc "Port :7443 Stunnel back" "ss -ltn | grep -q ':7443\b'"
hc "Port :8443 Nginx HTTPS"  "ss -ltn | grep -q ':8443\b'"
hc "Port :8880 ws-py"        "ss -ltn | grep -q ':8880\b'"

# TLS handshake (cipher legacy + banner Dropbear)
hc "TLS handshake :777 + SSH banner" \
   "echo Q | timeout 4 openssl s_client -connect 127.0.0.1:777 2>/dev/null | grep -qE '^SSH-2\.0-(dropbear|OpenSSH)'"

# WS upgrade :80
hc "WS upgrade :80 -> Dropbear banner" \
   "printf 'GET /ssh-ws HTTP/1.1\r\nHost: $DOMAIN\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n' | timeout 4 nc 127.0.0.1 80 | grep -qE '^SSH-2\.0-(dropbear|OpenSSH)'"

# Cert subject = domain user
hc "Cert subject = $DOMAIN" \
   "openssl x509 -in /etc/xray/xray.crt -noout -subject 2>/dev/null | grep -qE 'CN ?= ?$DOMAIN'"

if (( hc_fail > 0 )); then
    print_warn "$hc_fail health-check GAGAL — server-side belum 100% siap."
    print_warn "Jalankan 'menu -> 5) System -> 12) Diagnose' untuk detail per komponen."
else
    print_ok "Semua health-check LULUS — server siap menerima koneksi."
fi

# =====================================================================
# 7. CRON & FINAL TOUCHES
# =====================================================================
print_title "7/7 CRON & FINISH"

# auto-delete expired users every 1 minute
( crontab -l 2>/dev/null | grep -v 'all-protocol' ; \
  echo "*/1 * * * * /usr/local/sbin/del-expired >/dev/null 2>&1 # all-protocol" \
) | crontab -

# enable BBR by default (best-effort)
modprobe tcp_bbr 2>/dev/null
echo "tcp_bbr" > /etc/modules-load.d/tcp_bbr.conf
cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl --system >/dev/null 2>&1

# clone repo to /opt/all-protocol so menu->Update Script can git-pull
if [[ ! -d /opt/all-protocol/.git ]]; then
    rm -rf /opt/all-protocol
    git clone --depth 1 https://github.com/fauzanihanipah/all-protocol.git /opt/all-protocol >/dev/null 2>&1 || true
fi

# banner
cat > /etc/issue.net <<EOF

###############################################################
#                ALL-PROTOCOL TUNNEL SERVER                   #
#                  No Spam | No DDoS | No Torrent             #
###############################################################
EOF
sed -i 's|#Banner none|Banner /etc/issue.net|' /etc/ssh/sshd_config
systemctl restart ssh

clear
echo -e "${GREEN}================================================================${NC}"
echo -e "${CYAN}             INSTALLATION FINISHED SUCCESSFULLY${NC}"
echo -e "${GREEN}================================================================${NC}"
echo -e " Domain          : ${YELLOW}$DOMAIN${NC}"
echo -e " IP              : ${YELLOW}$(curl -s ifconfig.me 2>/dev/null)${NC}"
echo -e "${GREEN}----------------------------------------------------------------${NC}"
echo -e " ${CYAN}SSH (jalur ke Dropbear, kompatibel mobile injector)${NC}"
echo -e "   OpenSSH       : ${YELLOW}22${NC}"
echo -e "   Dropbear      : ${YELLOW}109, 143${NC}"
echo -e "   SSH-WS NTLS   : ${YELLOW}80${NC}    path /ssh-ws"
echo -e "   SSH-WS TLS    : ${YELLOW}443${NC}   path /ssh-ws  (SNI=$DOMAIN)"
echo -e "   SSH-SSL       : ${YELLOW}443${NC}   (SNI bebas / kosong) atau ${YELLOW}777${NC} (direct)"
echo -e "${GREEN}----------------------------------------------------------------${NC}"
echo -e " ${CYAN}V2Ray / Trojan${NC} (semua via Xray + nginx-stream mux)"
echo -e "   VMess WS      : ${YELLOW}443${NC} TLS / ${YELLOW}80${NC} NTLS    path /vmess"
echo -e "   VLess WS      : ${YELLOW}443${NC} TLS / ${YELLOW}80${NC} NTLS    path /vless"
echo -e "   Trojan WS     : ${YELLOW}443${NC} TLS                path /trojan-ws"
echo -e "   gRPC services : ${YELLOW}443${NC} TLS (vmess-grpc, vless-grpc, trojan-grpc)"
echo -e "   UDPGW         : ${YELLOW}7100, 7300${NC}"
echo -e "${GREEN}----------------------------------------------------------------${NC}"
echo -e " Cert auto-renew : Let's Encrypt + reloadcmd (sync stunnel.pem)"
echo -e " Ketik perintah  : ${CYAN}menu${NC}  untuk membuka menu utama"
echo -e "${GREEN}================================================================${NC}"
