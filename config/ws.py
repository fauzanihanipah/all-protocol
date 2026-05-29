#!/usr/bin/env python3
"""
ws-py: WebSocket-aware bridge for SSH-WS.

Listens on 127.0.0.1:8880. Every connection is bridged to 127.0.0.1:109 (Dropbear).

Two modes auto-detected from the incoming HTTP preamble:

1) "Real" WebSocket:
   - Client sent 'Sec-WebSocket-Key' header (HTTP Custom advanced payloads,
     anything that does proper RFC 6455 framing after the 101).
   - We respond with a proper 101 + Sec-WebSocket-Accept hash.
   - We DECODE incoming WebSocket frames (strip 2-14 byte header, unmask
     the payload) before forwarding bytes to Dropbear.
   - We WRAP each chunk from Dropbear in an unmasked binary frame
     (opcode 0x2, FIN=1) before sending back to the client.
   - Handle Ping (0x9) -> Pong (0xA), Close (0x8) -> tear down.

2) Legacy "fake WebSocket" tunnel:
   - Client sent only 'Upgrade: websocket' (no Sec-WebSocket-Key).
   - We send a plain 101 and bridge raw TCP both ways. This is what most
     SSH-tunnel apps (HTTP Injector, KPN, Netmod, simple HTTP Custom
     payloads) use.

Notes:
- TCP_NODELAY enabled on every socket: SSH key exchange is several small
  round-trips and Nagle's algorithm noticeably slows / breaks it.
- No idle timeout on the bridge (the previous 60s select timeout would
  break long-lived idle SSH sessions).
"""

import base64
import errno
import hashlib
import select
import socket
import struct
import sys
import threading

LISTEN = ("127.0.0.1", 8880)
TARGET = ("127.0.0.1", 109)
GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

PLAIN_RESPONSE = (
    b"HTTP/1.1 101 Switching Protocols\r\n"
    b"Upgrade: websocket\r\n"
    b"Connection: Upgrade\r\n\r\n"
)


def ws_response(key: bytes) -> bytes:
    accept = base64.b64encode(hashlib.sha1(key + GUID).digest())
    return (
        b"HTTP/1.1 101 Switching Protocols\r\n"
        b"Upgrade: websocket\r\n"
        b"Connection: Upgrade\r\n"
        b"Sec-WebSocket-Accept: " + accept + b"\r\n\r\n"
    )


def parse_headers(raw: bytes) -> dict:
    """Lowercase-keyed header dict from raw HTTP request bytes."""
    out = {}
    for line in raw.split(b"\r\n")[1:]:
        if not line:
            break
        if b":" in line:
            k, _, v = line.partition(b":")
            out[k.strip().lower().decode("latin-1", "replace")] = v.strip()
    return out


def encode_ws(payload: bytes, opcode: int = 0x2) -> bytes:
    """Server -> client: single FIN frame, no mask."""
    h = bytes([0x80 | (opcode & 0x0F)])
    n = len(payload)
    if n < 126:
        h += bytes([n])
    elif n < 65536:
        h += bytes([126]) + struct.pack("!H", n)
    else:
        h += bytes([127]) + struct.pack("!Q", n)
    return h + payload


def decode_ws_frames(buf: bytes):
    """
    Yield (opcode, payload) tuples consumed from buf.
    Returns (frames, leftover_buf).
    """
    frames = []
    while len(buf) >= 2:
        b0, b1 = buf[0], buf[1]
        opcode = b0 & 0x0F
        masked = bool(b1 & 0x80)
        plen = b1 & 0x7F
        idx = 2
        if plen == 126:
            if len(buf) < idx + 2:
                break
            plen = struct.unpack("!H", buf[idx:idx + 2])[0]
            idx += 2
        elif plen == 127:
            if len(buf) < idx + 8:
                break
            plen = struct.unpack("!Q", buf[idx:idx + 8])[0]
            idx += 8
        if masked:
            if len(buf) < idx + 4:
                break
            mask = buf[idx:idx + 4]
            idx += 4
        else:
            mask = None
        if len(buf) < idx + plen:
            break
        payload = buf[idx:idx + plen]
        if mask is not None:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        frames.append((opcode, payload))
        buf = buf[idx + plen:]
    return frames, buf


def set_nodelay(sock: socket.socket) -> None:
    try:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    except OSError:
        pass


def bridge_plain(client: socket.socket, target: socket.socket) -> None:
    socks = [client, target]
    try:
        while True:
            r, _, _ = select.select(socks, [], [])
            if not r:
                break
            for s in r:
                try:
                    d = s.recv(16384)
                except OSError:
                    return
                if not d:
                    return
                dst = target if s is client else client
                try:
                    dst.sendall(d)
                except OSError:
                    return
    except (OSError, ConnectionError):
        pass


def bridge_ws(client: socket.socket, target: socket.socket) -> None:
    """Frame-aware bridge.

    Client -> us  : masked WS frames; we strip framing, forward raw bytes to Dropbear.
    Us -> client  : raw bytes from Dropbear, wrapped in single-frame binary message.
    """
    pending = b""
    socks = [client, target]
    try:
        while True:
            r, _, _ = select.select(socks, [], [])
            if not r:
                break
            for s in r:
                try:
                    d = s.recv(16384)
                except OSError:
                    return
                if not d:
                    return
                if s is client:
                    pending += d
                    frames, pending = decode_ws_frames(pending)
                    for opcode, payload in frames:
                        if opcode == 0x8:  # close
                            return
                        if opcode == 0x9:  # ping -> pong
                            try:
                                client.sendall(encode_ws(payload, opcode=0xA))
                            except OSError:
                                return
                            continue
                        if opcode == 0xA:  # pong (ignore)
                            continue
                        # 0x0 continuation, 0x1 text, 0x2 binary all carry SSH bytes
                        if payload:
                            try:
                                target.sendall(payload)
                            except OSError:
                                return
                else:
                    # Dropbear -> client; wrap each chunk in a single binary frame
                    try:
                        client.sendall(encode_ws(d, opcode=0x2))
                    except OSError:
                        return
    except (OSError, ConnectionError):
        pass


def handle(client: socket.socket) -> None:
    target = None
    try:
        set_nodelay(client)
        client.settimeout(15)

        # Read HTTP preamble until end of headers
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = client.recv(4096)
            if not chunk:
                return
            data += chunk
            if len(data) > 32768:
                return
        client.settimeout(None)

        headers = parse_headers(data)
        ws_key = headers.get("sec-websocket-key")

        target = socket.create_connection(TARGET)
        set_nodelay(target)
        target.settimeout(None)

        if ws_key:
            # Proper WebSocket: respond with Accept hash, do framed bridging
            client.sendall(ws_response(ws_key))
            bridge_ws(client, target)
        else:
            # Legacy/fake WebSocket: plain 101, raw bridge
            client.sendall(PLAIN_RESPONSE)
            bridge_plain(client, target)
    except Exception:
        # Best-effort: never let one connection take down the listener
        pass
    finally:
        for s in (client, target):
            if s is None:
                continue
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                s.close()
            except OSError:
                pass


def main() -> None:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(LISTEN)
    s.listen(128)
    sys.stdout.write(
        f"ws-py listening on {LISTEN[0]}:{LISTEN[1]} -> {TARGET[0]}:{TARGET[1]}\n"
    )
    sys.stdout.flush()
    while True:
        c, _ = s.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()


if __name__ == "__main__":
    main()
