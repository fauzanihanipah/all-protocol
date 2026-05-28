#!/usr/bin/env python3
# Minimal WebSocket -> SSH bridge (fallback if /usr/local/bin/ws fails).
# Listens on 127.0.0.1:8880, every connection is forwarded to 127.0.0.1:22.
# Behaves like a tunnel that returns "101 Switching Protocols" so most SSH
# tunnel clients are happy.

import socket, threading, select, sys

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 8880
TARGET_HOST = "127.0.0.1"
TARGET_PORT = 22

RESPONSE = (
    b"HTTP/1.1 101 Switching Protocols\r\n"
    b"Upgrade: websocket\r\n"
    b"Connection: Upgrade\r\n\r\n"
)

def pipe(a, b):
    try:
        while True:
            r, _, _ = select.select([a, b], [], [], 60)
            if not r: break
            for s in r:
                d = s.recv(8192)
                if not d: return
                (b if s is a else a).sendall(d)
    except OSError:
        return
    finally:
        for s in (a, b):
            try: s.close()
            except: pass

def handle(client):
    try:
        # read & discard request headers
        client.settimeout(10)
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = client.recv(4096)
            if not chunk: return
            data += chunk
            if len(data) > 8192: return
        client.sendall(RESPONSE)
        client.settimeout(None)

        target = socket.create_connection((TARGET_HOST, TARGET_PORT))
        pipe(client, target)
    except Exception as e:
        try: client.close()
        except: pass

def main():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((LISTEN_HOST, LISTEN_PORT))
    s.listen(128)
    print(f"ws-py listening on {LISTEN_HOST}:{LISTEN_PORT} -> {TARGET_HOST}:{TARGET_PORT}")
    while True:
        c, _ = s.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()

if __name__ == "__main__":
    main()
