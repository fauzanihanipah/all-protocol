#!/bin/bash
# fix-services.sh — self-contained repair for nginx/stunnel/ws/udpgw OFF.
# All config & service files are embedded inline via heredoc, so this
# script does NOT depend on any repo files being on disk.
#
# Usage:
#   bash <(curl -sL https://raw.githubusercontent.com/fauzanihanipah/all-protocol/main/fix-services.sh)

set -e
[[ $EUID -ne 0 ]] && { echo "Run as root"; exit 1; }

GREEN=$'\033[1;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[1;31m'; CYAN=$'\033[1;36m'; NC=$'\033[0m'
log()  { echo -e " ${GREEN}[*]${NC} $*"; }
warn() { echo -e " ${YELLOW}[!]${NC} $*"; }
fail() { echo -e " ${RED}[X]${NC} $*"; }

DOMAIN=$(cat /etc/xray/domain 2>/dev/null || cat /root/domain 2>/dev/null || echo "")
if [[ -z "$DOMAIN" ]]; then
    read -rp " Domain belum tersimpan. Masukkan domain: " DOMAIN
    [[ -z "$DOMAIN" ]] && { fail "Domain wajib"; exit 1; }
    mkdir -p /etc/xray
    echo "$DOMAIN" > /etc/xray/domain
fi
log "Domain : $DOMAIN"

# ====================================================================
# 1) install missing dependencies
# ====================================================================
log "Ensuring packages: nginx + stream module, stunnel..."
need_apt_update=1
have_pkg() { dpkg -l "$1" 2>/dev/null | grep -q "^ii"; }

if ! have_pkg libnginx-mod-stream && ! nginx -V 2>&1 | grep -q -- '--with-stream'; then
    [[ $need_apt_update -eq 1 ]] && { apt-get update -y >/dev/null; need_apt_update=0; }
    DEBIAN_FRONTEND=noninteractive apt-get install -y libnginx-mod-stream >/dev/null
    log "libnginx-mod-stream installed"
fi

# Ensure the module is actually loadable. Some installs don't auto-create
# /etc/nginx/modules-enabled/50-mod-stream.conf — write it ourselves if missing.
mkdir -p /etc/nginx/modules-enabled
if ! ls /etc/nginx/modules-enabled/*.conf 2>/dev/null | xargs grep -lE 'ngx_stream_module' >/dev/null 2>&1; then
    STREAM_SO=$(find /usr/lib/nginx/modules /usr/share/nginx/modules \
                     -name 'ngx_stream_module.so' 2>/dev/null | head -1)
    if [[ -n "$STREAM_SO" ]]; then
        echo "load_module $STREAM_SO;" > /etc/nginx/modules-enabled/50-mod-stream.conf
        log "Manually wired stream module: $STREAM_SO"
    else
        fail "ngx_stream_module.so NOT FOUND on system. Install nginx-full or nginx-extras and rerun."
        apt-cache search nginx | grep -i mod-stream | sed 's/^/    /'
        exit 1
    fi
fi

# stunnel package detection
STUNNEL_PKG=stunnel4
if ! apt-cache show stunnel4 >/dev/null 2>&1; then STUNNEL_PKG=stunnel; fi
if ! have_pkg "$STUNNEL_PKG"; then
    [[ $need_apt_update -eq 1 ]] && { apt-get update -y >/dev/null; need_apt_update=0; }
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$STUNNEL_PKG" >/dev/null
fi
STUNNEL_SVC=stunnel4
systemctl list-unit-files 2>/dev/null | grep -q '^stunnel4\.service' || STUNNEL_SVC=stunnel
log "stunnel package=$STUNNEL_PKG service=$STUNNEL_SVC"

# ====================================================================
# 2) write nginx.conf (with stream block) + vhost
# ====================================================================
log "Writing /etc/nginx/nginx.conf ..."
cat > /etc/nginx/nginx.conf <<'NGINXCONF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;

# Load dynamic modules (libnginx-mod-stream lands here on Debian/Ubuntu)
include /etc/nginx/modules-enabled/*.conf;

events { worker_connections 4096; multi_accept on; }

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;
    client_max_body_size 16m;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /var/log/nginx/access.log;
    error_log  /var/log/nginx/error.log warn;
    gzip on;

    include /etc/nginx/conf.d/*.conf;
}

stream {
    log_format basic '$remote_addr [$time_local] $protocol "$ssl_preread_server_name"';
    access_log /var/log/nginx/stream.log basic;

    map $ssl_preread_server_name $upstream_443 {
        default               ssh_ssl_backend;
        ~.*                   tls_backend;
    }
    upstream tls_backend     { server 127.0.0.1:8443; }
    upstream ssh_ssl_backend { server 127.0.0.1:7443; }

    server {
        listen 443 reuseport;
        listen [::]:443 reuseport;
        proxy_pass $upstream_443;
        ssl_preread on;
        proxy_timeout 300s;
    }
}
NGINXCONF

log "Writing /etc/nginx/conf.d/all-protocol.conf ..."
mkdir -p /etc/nginx/conf.d
rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf 2>/dev/null
cat > /etc/nginx/conf.d/all-protocol.conf <<NGINXVHOST
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name $DOMAIN;
    location = / { return 200 "OK\n"; default_type text/plain; }

    location /ssh-ws {
        proxy_pass http://127.0.0.1:8880;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 7200s;
    }
    location /vmess {
        if (\$http_upgrade != "websocket") { return 404; }
        proxy_pass http://127.0.0.1:10000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 7200s;
    }
    location /vless {
        if (\$http_upgrade != "websocket") { return 404; }
        proxy_pass http://127.0.0.1:10001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 7200s;
    }
}

server {
    listen 127.0.0.1:8443 ssl http2;
    server_name $DOMAIN;
    ssl_certificate     /etc/xray/xray.crt;
    ssl_certificate_key /etc/xray/xray.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;

    location / { return 200 "Welcome\n"; default_type text/plain; }

    location /ssh-ws {
        proxy_pass http://127.0.0.1:8880;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 7200s;
    }
    location /vmess {
        if (\$http_upgrade != "websocket") { return 404; }
        proxy_pass http://127.0.0.1:10000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 7200s;
    }
    location /vless {
        if (\$http_upgrade != "websocket") { return 404; }
        proxy_pass http://127.0.0.1:10001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 7200s;
    }
    location /trojan-ws {
        if (\$http_upgrade != "websocket") { return 404; }
        proxy_pass http://127.0.0.1:10002;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 7200s;
    }
    location ^~ /vmess-grpc  { grpc_pass grpc://127.0.0.1:10003; grpc_set_header Host \$host; }
    location ^~ /vless-grpc  { grpc_pass grpc://127.0.0.1:10004; grpc_set_header Host \$host; }
    location ^~ /trojan-grpc { grpc_pass grpc://127.0.0.1:10005; grpc_set_header Host \$host; }
}
NGINXVHOST

# ====================================================================
# 3) Stunnel config + cert
# ====================================================================
log "Writing /etc/stunnel/stunnel.conf ..."
mkdir -p /etc/stunnel
cat > /etc/stunnel/stunnel.conf <<'STUNNEL'
cert    = /etc/stunnel/stunnel.pem
client  = no
pid     = /var/run/stunnel.pid
output  = /var/log/stunnel.log
debug   = 4
sslVersion = all

[ssh-ssl-backend]
accept  = 127.0.0.1:7443
connect = 127.0.0.1:22

[ssh-ssl-public]
accept  = 0.0.0.0:777
connect = 127.0.0.1:22
STUNNEL

if [[ -s /etc/xray/xray.crt && -s /etc/xray/xray.key ]]; then
    cat /etc/xray/xray.key /etc/xray/xray.crt > /etc/stunnel/stunnel.pem
    chmod 640 /etc/stunnel/stunnel.pem
    chown root:root /etc/stunnel/stunnel.pem
    log "Stunnel cert assembled."
else
    fail "/etc/xray/xray.crt or .key missing - regenerating self-signed."
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout /etc/xray/xray.key -out /etc/xray/xray.crt \
        -subj "/CN=$DOMAIN" -days 825 >/dev/null 2>&1
    cat /etc/xray/xray.key /etc/xray/xray.crt > /etc/stunnel/stunnel.pem
    chmod 640 /etc/stunnel/stunnel.pem
fi
sed -i 's|^ENABLED=.*|ENABLED=1|' /etc/default/stunnel4 2>/dev/null || true

# ====================================================================
# 4) ws-py (Python WS-to-SSH bridge) + ws.service
# ====================================================================
log "Writing /usr/local/bin/ws-py ..."
cat > /usr/local/bin/ws-py <<'WSPY'
#!/usr/bin/env python3
import socket, threading, select
LISTEN_HOST="127.0.0.1"; LISTEN_PORT=8880
TARGET_HOST="127.0.0.1"; TARGET_PORT=22
RESPONSE = (b"HTTP/1.1 101 Switching Protocols\r\n"
            b"Upgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
def pipe(a,b):
    try:
        while True:
            r,_,_=select.select([a,b],[],[],60)
            if not r: break
            for s in r:
                d=s.recv(8192)
                if not d: return
                (b if s is a else a).sendall(d)
    except OSError: return
    finally:
        for s in (a,b):
            try: s.close()
            except: pass
def handle(c):
    try:
        c.settimeout(10); data=b""
        while b"\r\n\r\n" not in data:
            ch=c.recv(4096)
            if not ch: return
            data+=ch
            if len(data)>8192: return
        c.sendall(RESPONSE); c.settimeout(None)
        t=socket.create_connection((TARGET_HOST,TARGET_PORT))
        pipe(c,t)
    except: 
        try: c.close()
        except: pass
def main():
    s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
    s.bind((LISTEN_HOST,LISTEN_PORT)); s.listen(128)
    print(f"ws-py {LISTEN_HOST}:{LISTEN_PORT} -> {TARGET_HOST}:{TARGET_PORT}", flush=True)
    while True:
        c,_=s.accept()
        threading.Thread(target=handle,args=(c,),daemon=True).start()
main()
WSPY
chmod +x /usr/local/bin/ws-py

log "Writing /etc/systemd/system/ws.service ..."
cat > /etc/systemd/system/ws.service <<'WSUNIT'
[Unit]
Description=All-Protocol WS Proxy (SSH-WebSocket bridge)
After=network.target ssh.service
Requires=ssh.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/ws-py
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
WSUNIT

# ====================================================================
# 5) UDPGW wrapper + runn.service
# ====================================================================
log "Writing /usr/local/bin/run-udpgw + runn.service ..."
cat > /usr/local/bin/run-udpgw <<'WRAP'
#!/bin/sh
trap 'kill 0' EXIT TERM INT
/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7100 --max-clients 500 --max-connections-for-client 10 &
/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 500 --max-connections-for-client 10 &
wait
WRAP
chmod +x /usr/local/bin/run-udpgw

if [[ ! -x /usr/local/bin/badvpn-udpgw ]]; then
    log "Downloading badvpn-udpgw..."
    wget -q https://raw.githubusercontent.com/chanelog/max/main/udpgw -O /usr/local/bin/badvpn-udpgw
    chmod +x /usr/local/bin/badvpn-udpgw
fi

cat > /etc/systemd/system/runn.service <<'RUNN'
[Unit]
Description=BadVPN UDPGW (UDP forwarder)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/run-udpgw
Restart=on-failure
RestartSec=3
KillMode=control-group

[Install]
WantedBy=multi-user.target
RUNN

# ====================================================================
# 6) Test nginx & restart everything
# ====================================================================
log "Testing nginx config..."
if ! nginx -t 2>&1 | sed 's/^/    /'; then
    fail "nginx config error - aborting"
    exit 1
fi

systemctl daemon-reload
for svc in nginx "$STUNNEL_SVC" ws runn xray dropbear; do
    systemctl enable "$svc" >/dev/null 2>&1
    systemctl restart "$svc" 2>/dev/null
    sleep 1
    if systemctl is-active --quiet "$svc"; then
        log "$svc ${GREEN}ON${NC}"
    else
        fail "$svc still failing - last log:"
        journalctl -u "$svc" -n 6 --no-pager 2>/dev/null | sed 's/^/    /'
    fi
done

log "Selesai. Coba: ${CYAN}menu${NC}  -> 5) System -> 12) Diagnose"
