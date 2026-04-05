"""TCP throttle proxy for E2E testing. Applies TCP backpressure to the server.

The proxy reads from the server at a limited rate, causing the kernel TCP
buffer to fill up. This simulates a slow network and forces the ET server
to deal with backpressure.

Client->server direction (keystrokes, Ctrl-C) is forwarded at full speed.

Usage: python3 throttle_proxy.py <listen_port> <target_port> [bytes_per_sec]
"""
import socket, sys, threading, time, select

LISTEN_PORT, TARGET_PORT = int(sys.argv[1]), int(sys.argv[2])
RATE = int(sys.argv[3]) if len(sys.argv) > 3 else 100000


def throttled_forward(name, src, dst, rate, stop):
    total = 0
    CHUNK = max(rate // 20, 64)
    last_t = time.time()
    try:
        while not stop.is_set():
            data = src.recv(CHUNK)
            if not data:
                break
            dst.sendall(data)
            total += len(data)
            time.sleep(len(data) / rate)
            now = time.time()
            if now - last_t > 2:
                print(f"[proxy] {name}: sent={total:,}B", flush=True)
                last_t = now
    except Exception:
        pass
    stop.set()


def fast_forward(name, src, dst, stop):
    try:
        while not stop.is_set():
            data = src.recv(4096)
            if not data:
                break
            dst.sendall(data)
    except Exception:
        pass
    stop.set()


def handle(cli, addr):
    print(f"[proxy] connect {addr}", flush=True)
    srv = None
    try:
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.connect(("127.0.0.1", TARGET_PORT))
        stop = threading.Event()
        t1 = threading.Thread(
            target=throttled_forward,
            args=("s->c", srv, cli, RATE, stop),
            daemon=True,
        )
        t2 = threading.Thread(
            target=fast_forward, args=("c->s", cli, srv, stop), daemon=True
        )
        t1.start()
        t2.start()
        t1.join()
        t2.join()
    except Exception as e:
        print(f"[proxy] error: {e}", flush=True)
    finally:
        for s in (cli, srv):
            try:
                s.close()
            except Exception:
                pass
    print(f"[proxy] disconnect {addr}", flush=True)


# Dual-stack listener (accepts both IPv4 and IPv6-mapped IPv4)
s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
s.bind(("::", LISTEN_PORT))
s.listen(5)
s.setblocking(False)
print(f"[proxy] [::]:{LISTEN_PORT} -> 127.0.0.1:{TARGET_PORT} rate={RATE}B/s", flush=True)
while True:
    try:
        r, _, _ = select.select([s], [], [], 1.0)
        for _ in r:
            c, a = s.accept()
            threading.Thread(target=handle, args=(c, a), daemon=True).start()
    except KeyboardInterrupt:
        break
    except Exception:
        pass
