# Payload Reference — SSH-WS TLS & Non-TLS

Referensi payload untuk aplikasi tunneling (HTTP Custom, HTTP Injector,
KPN Tunnel, eVPN, NetMod, Dark Tunnel, dll).

> Ganti `tunnel.fauzan.dev` dengan domain yang dipakai waktu install,
> dan ganti `bug.host.com` dengan bug host operator yang sesuai.

---

## 1. Settings Dasar

| Item              | SSH-WS Non-TLS               | SSH-WS TLS                   |
|-------------------|------------------------------|------------------------------|
| Proxy host        | IP VPS / domain              | IP VPS / domain              |
| Proxy port        | `80`                         | `443`                        |
| SSL/TLS           | OFF                          | ON                           |
| SNI               | —                            | `tunnel.fauzan.dev`          |
| WebSocket path    | `/ssh-ws`                    | `/ssh-ws`                    |
| SSH host          | `127.0.0.1`                  | `127.0.0.1`                  |
| SSH port          | `22`                         | `22`                         |

> Catatan: pakai `127.0.0.1` sebagai SSH host (bukan IP publik) supaya
> trafik benar-benar lewat jalur WebSocket, bukan TCP langsung ke 22.

---

## 2. Payload Non-TLS (port 80)

### 2.1 Standard
```
GET ws://[host]/ssh-ws HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]
```

### 2.2 Front Injection
```
GET / HTTP/1.1[crlf]Host: [host][crlf][crlf]GET ws://[host]/ssh-ws HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf][crlf]
```

### 2.3 Bug Host
```
GET / HTTP/1.1[crlf]Host: bug.host.com[crlf][crlf]GET ws://tunnel.fauzan.dev/ssh-ws HTTP/1.1[crlf]Host: tunnel.fauzan.dev[crlf]Upgrade: websocket[crlf][crlf]
```

### 2.4 CONNECT method
```
CONNECT [host_port] HTTP/1.1[crlf]Host: [host][crlf][crlf]
```

### 2.5 With User-Agent
```
GET /ssh-ws HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf]User-Agent: [ua][crlf]Connection: Upgrade[crlf][crlf]
```

---

## 3. Payload TLS (port 443)

> Karena server pakai Nginx **stream SNI multiplexer** di port 443:
> - **SNI = domain VPS** → masuk SSH-WS-TLS / V2Ray (lewat Nginx HTTPS)
> - **SNI ≠ domain VPS** → masuk SSH-SSL (Stunnel)
>
> Jadi untuk SSH-WS-TLS, **SNI wajib di-set ke domain VPS**.
> Kalau mau pakai bug-SNI bypass, gunakan **SSH-SSL** (jalur 443 default).

### 3.1 Standard WSS
```
GET wss://[host]/ssh-ws HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]
```

### 3.2 Dual Header (front + real)
```
GET / HTTP/1.1[crlf]Host: [host][crlf][crlf]GET wss://[host]/ssh-ws HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf]User-Agent: [ua][crlf][crlf]
```

### 3.3 Khusus bug host (lewat SSH-SSL, bukan WS)
SSH-SSL = TLS murni → SSH 22. Tidak butuh payload, hanya butuh:
- Proxy: bug host : 443
- SNI: bug host
- Akan otomatis fallback ke Stunnel di server karena SNI tidak match domain

---

## 4. Format per Aplikasi

### 4.1 HTTP Custom (Android)
- **Payload:**
  ```
  GET wss://[host]/ssh-ws HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf][crlf]
  ```
- SSL/TLS: ON (port 443) atau OFF (port 80)
- SNI: `tunnel.fauzan.dev`
- Proxy Type: HTTP
- Proxy Server: `tunnel.fauzan.dev:443`

### 4.2 HTTP Injector (Android)
- Mode: Direct SSH atau SSH+WebSocket
- Inject Method: Front Injection
- URL: `wss://tunnel.fauzan.dev`
- Custom Header: `Upgrade: websocket`
- Online Host: `tunnel.fauzan.dev`
- Manual payload (Direct Mode):
  ```
  GET wss://tunnel.fauzan.dev/ssh-ws HTTP/1.1[crlf]Host: tunnel.fauzan.dev[crlf]Upgrade: websocket[crlf][crlf]
  ```

### 4.3 KPN Tunnel Revolution
- Mode: `WS / WSS`
- Path: `/ssh-ws`
- Server: `tunnel.fauzan.dev`
- Port: `443` (TLS) / `80` (NTLS)
- SNI: `tunnel.fauzan.dev` (TLS only)

### 4.4 eVPN / NetMod / Dark Tunnel
```
GET /ssh-ws HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]
```
Mode WebSocket, port 80/443, TLS sesuai port.

---

## 5. Placeholder reference

| Placeholder    | Arti                                            |
|----------------|-------------------------------------------------|
| `[crlf]`       | `\r\n` (carriage return + line feed)            |
| `[lf]`         | `\n`                                            |
| `[cr]`         | `\r`                                            |
| `[host]`       | Host header value (= domain VPS biasanya)       |
| `[host_port]`  | `host:port`                                     |
| `[ua]`         | User-Agent dari aplikasi                        |
| `[real_raw]`   | Raw request asli sebelum injeksi                |

---

## 6. Verifikasi server (dari laptop)

### Non-TLS
```bash
curl -i -N \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  http://tunnel.fauzan.dev/ssh-ws
```

### TLS
```bash
curl -i -N -k \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  https://tunnel.fauzan.dev/ssh-ws
```

Respons benar:
```
HTTP/1.1 101 Switching Protocols
Upgrade: websocket
Connection: Upgrade
```

Kalau respons `404` → path salah.
Kalau respons `400` → header WS upgrade hilang/salah.
Kalau koneksi timeout → port tidak listen / firewall blok.

---

## 7. Sample lengkap (siap copy-paste)

### Non-TLS
```
Server : tunnel.fauzan.dev
Port   : 80
SSL    : OFF
Path   : /ssh-ws

Payload:
GET ws://tunnel.fauzan.dev/ssh-ws HTTP/1.1[crlf]Host: tunnel.fauzan.dev[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]
```

### TLS
```
Server : tunnel.fauzan.dev
Port   : 443
SSL    : ON
SNI    : tunnel.fauzan.dev
Path   : /ssh-ws

Payload:
GET wss://tunnel.fauzan.dev/ssh-ws HTTP/1.1[crlf]Host: tunnel.fauzan.dev[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]
```
