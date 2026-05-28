# All-Protocol Tunnel

Installer all-in-one untuk VPS yang menyediakan beberapa protokol tunneling sekaligus dengan menu yang rapih.

## Fitur

| Protokol         | Port    | Keterangan                                      |
|------------------|---------|-------------------------------------------------|
| OpenSSH          | 22      | Default                                         |
| Dropbear         | 109,143 | SSH alternatif                                  |
| SSH-WS Non-TLS   | 80      | path `/ssh-ws`                                  |
| SSH-WS TLS       | 443     | path `/ssh-ws` (SNI = domain)                   |
| SSH-SSL          | 443     | default backend (no SNI / SNI mismatch) + 777   |
| VMess WS NTLS    | 80      | path `/vmess`                                   |
| VMess WS TLS     | 443     | path `/vmess`                                   |
| VMess gRPC       | 443     | serviceName `vmess-grpc`                        |
| VLess WS NTLS    | 80      | path `/vless`                                   |
| VLess WS TLS     | 443     | path `/vless`                                   |
| VLess gRPC       | 443     | serviceName `vless-grpc`                        |
| Trojan WS TLS    | 443     | path `/trojan-ws`                               |
| Trojan gRPC      | 443     | serviceName `trojan-grpc`                       |
| BadVPN UDPGW     | 7100, 7300 | UDP forwarder untuk SSH/SSL clients          |

### Trik port 443 "khusus" untuk SSH-SSL

Karena SSH-SSL dan V2Ray sama-sama mau pakai 443, Nginx dijalankan dalam mode `stream` sebagai **SNI multiplexer**:

```
Client TLS connect ke :443
        │
        ├── SNI = domain user  →  Nginx HTTPS internal (8443) → V2Ray + SSH-WS-TLS + Trojan
        └── No SNI / mismatch  →  Stunnel (7443) → OpenSSH 22  (= SSH-SSL murni)
```

Stunnel juga tetap listen langsung di **777** sebagai fallback klasik.

## Instalasi

VPS support: Ubuntu 20.04 / 22.04 / Debian 10 / 11. Jalankan sebagai root.

```bash
git clone https://github.com/fauzanihanipah/all-protocol.git
cd all-protocol
chmod +x install.sh
./install.sh
```

Saat instalasi, kamu akan diminta mengisi **domain**. Pastikan A-record domain sudah mengarah ke IP VPS sebelum mulai (dipakai untuk issue Let's Encrypt cert via acme.sh, mode standalone).

Setelah selesai, panggil menu:

```bash
menu
```

## Menu Layout

```
╔══════════════════════════════════════════════════════════════╗
║            ALL-PROTOCOL TUNNEL  -  CONTROL PANEL             ║
╠══════════════════════════════════════════════════════════════╣
║ IP        : 1.2.3.4                                          ║
║ Domain    : tunnel.example.com                               ║
║ Uptime    : 1 hour, 23 minutes                               ║
║ Memory    : 312M / 2048M                                     ║
╠══════════════════════════════════════════════════════════════╣
║ Service : ssh ON  dropbear ON  nginx ON  xray ON  ...        ║
╠══════════════════════════════════════════════════════════════╣
║ Active users : SSH=2  VMess=3  VLess=1  Trojan=0             ║
╠══════════════════════════════════════════════════════════════╣
║  1) Menu SSH / SSH-WS / SSH-SSL                              ║
║  2) Menu V2Ray VMess                                         ║
║  3) Menu V2Ray VLess                                         ║
║  4) Menu Trojan                                              ║
║  5) Menu System                                              ║
║  6) Restart All Services                                     ║
║  0) Exit                                                     ║
╚══════════════════════════════════════════════════════════════╝
```

Setiap submenu mendukung: tambah, hapus, list, perpanjang, akun trial 1 hari, dan restart service.

## Binary yang dipakai

Hanya 4 binary yang diunduh dari URL yang kamu sediakan:
- `XRAY_URL`         → Xray-core (untuk VMess, VLess, Trojan — tidak perlu Trojan-Go terpisah)
- `UDPGW_URL`        → badvpn-udpgw (UDP forwarder)
- `WS_URL`           → ws (SSH-WS proxy daemon)
- `WS_SERVICE_URL`   → service systemd untuk ws

`HYSTERIA_URL`, `TROJAN_GO_URL`, `SLOWDNS_URL`, `OHP_URL` **tidak dipakai** karena tidak diminta dan fungsinya sudah tercover oleh Xray.

## Auto-cleanup user expired

Cron `*/1 * * * *` menjalankan `del-expired` yang:
- Menghapus user SSH yang `chage -E` sudah lewat
- Menghapus client Xray (VMess/VLess/Trojan) yang field `expiry` (epoch) sudah lewat, lalu restart Xray bila ada perubahan

## File Layout

```
all-protocol/
├── install.sh                        # Installer utama
├── lib/common.sh                     # UI helpers + xray jq helpers
├── config/
│   ├── xray.json                     # 6 inbound (vmess/vless/trojan x ws/grpc)
│   ├── nginx.conf                    # http + stream SNI mux
│   ├── nginx-vhost.conf              # HTTP:80 + HTTPS:8443 internal
│   ├── stunnel.conf                  # SSH-SSL backend
│   ├── dropbear                      # /etc/default/dropbear
│   └── ws.py                         # Fallback SSH-WS proxy
├── service/
│   ├── runn.service                  # badvpn-udpgw
│   └── xray.service
├── menu/
│   ├── menu, m-ssh, m-vmess, m-vless, m-trojan, m-system
└── user/
    ├── add-/del-/list-/trial-/renew-  ssh, vmess, vless, trojan
    ├── cek-ssh
    └── del-expired                   # cron hook
```

## Catatan

- File config Nginx menulis sertifikat dari `/etc/xray/xray.crt` dan `/etc/xray/xray.key`, sama dengan sumber buat `stunnel.pem`. Renew SSL bisa via menu System → 7.
- Default fallback (`SNI mismatch → stunnel`) bisa membuat scanner port menyangka 443 adalah server SSH biasa — hal ini disengaja agar SSH-SSL tetap bekerja meski client tidak set SNI.
