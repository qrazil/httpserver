"""Streaming, keep-alive and concurrency. Works over plain TCP and TLS.
Usage: static_stream.py PORT ROOT SERVER-PID [CAFILE]   (CAFILE: use TLS to localhost)"""
import hashlib
import os
import socket
import sys
import threading
import time

from static_common import *

port, root, pid = int(sys.argv[1]), sys.argv[2], int(sys.argv[3])
cafile = sys.argv[4] if len(sys.argv) > 4 else None
host = "localhost" if cafile else "127.0.0.1"
kind = "https" if cafile else "http"
kw = dict(host=host, cafile=cafile)


def filesha(name):
    h = hashlib.sha256()
    with open(os.path.join(root, name), "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


BIG = os.environ.get("STREAM_BIG", "big.bin")
big_size = os.path.getsize(os.path.join(root, BIG))
big_sha = filesha(BIG)
mid_size = os.path.getsize(os.path.join(root, "mid.bin"))
mid = open(os.path.join(root, "mid.bin"), "rb").read()

# --- 1. a big file, in constant memory, bit-exact ---
rss_before = rss_kb(pid)
peak = [rss_before]
stop = threading.Event()


def sampler():
    while not stop.is_set():
        peak[0] = max(peak[0], rss_kb(pid))
        time.sleep(0.02)


t = threading.Thread(target=sampler, daemon=True)
t.start()
t0 = time.time()
r = get(port, "/" + BIG, **kw)  # holds the whole thing in this process, not the server
took = time.time() - t0
stop.set()
t.join()
check("%s: %d MiB %s: 200, Content-Length exact, sha256 matches" % (kind, big_size >> 20, BIG),
      r and r.status == 200 and r.h("content-length") == str(big_size) and r.length_read == big_size and r.sha256 == big_sha,
      r and (r.status, r.h("content-length"), getattr(r, "length_read", None)))
growth = (peak[0] - rss_before) // 1024
print("     %s %.1f s (%.0f MB/s); server RSS %d MB -> peak %d MB" % (BIG, took, big_size / took / 1e6, rss_before // 1024, peak[0] // 1024), flush=True)
check("%s: server memory stays flat while streaming %d MiB (RSS growth %d MB < 24 MB)" % (kind, big_size >> 20, growth),
      0 <= growth < 24 or rss_before < 0, rss_before, peak[0])

# HEAD of a big file is instant and has no body
t0 = time.time()
r = get(port, "/" + BIG, method=b"HEAD", **kw)
check("%s: HEAD %s: Content-Length only, no body, fast" % (kind, BIG),
      r.status == 200 and r.h("content-length") == str(big_size) and r.body == b"" and time.time() - t0 < 2)

# --- 2. big ranges, bit-exact (offset is read-and-discarded, so the middle of a 64 MiB file is a real test) ---
def range_sha(a, b):
    r = get(port, "/" + BIG, ("Range: bytes=%s\r\n" % (a if b is None else "%d-%d" % (a, b))).encode(), **kw)
    return r


h = hashlib.sha256()
with open(os.path.join(root, BIG), "rb") as f:
    f.seek(big_size // 2)
    want = f.read(5 << 20)
r = range_sha(big_size // 2, big_size // 2 + (5 << 20) - 1)
check("%s: 5 MiB from the middle of %s: 206, exact bytes" % (kind, BIG),
      r.status == 206 and r.body == want and r.h("content-range") == "bytes %d-%d/%d" % (big_size // 2, big_size // 2 + (5 << 20) - 1, big_size))
r = get(port, "/" + BIG, b"Range: bytes=-1000\r\n", **kw)
with open(os.path.join(root, BIG), "rb") as f:
    f.seek(big_size - 1000)
    tail = f.read()
check("%s: last 1000 bytes of %s" % (kind, BIG), r.status == 206 and r.body == tail)
r = get(port, "/" + BIG, ("Range: bytes=%d-\r\n" % (big_size - 1)).encode(), **kw)
check("%s: last single byte, open-ended" % kind, r.status == 206 and len(r.body) == 1 and r.body == tail[-1:])
r = get(port, "/" + BIG, ("Range: bytes=%d-\r\n" % big_size).encode(), **kw)
check("%s: range starting at the size -> 416" % kind, r.status == 416)

# --- 3. keep-alive: many requests, one connection, framing intact around a streamed body ---
sock = connect(port, **kw)
seq = [("/hello.txt", b"GET", 200), ("/mid.bin", b"GET", 200), ("/nope", b"GET", 404), ("/mid.bin", b"HEAD", 200),
       ("/hello.txt", b"GET", 200), ("/sub", b"GET", 301), ("/mid.bin", b"GET", 200), ("/.hidden", b"GET", 404),
       ("/hello.txt", b"HEAD", 200), ("/mid.bin", b"GET", 206), ("/hello.txt", b"POST", 405), ("/hello.txt", b"GET", 200)]
good = True
detail = None
for i, (path, method, want_status) in enumerate(seq):
    extra = b"Range: bytes=100-199\r\n" if want_status == 206 else b""
    sock.sendall(method + b" " + path.encode() + b" HTTP/1.1\r\nHost: x\r\n" + extra + b"\r\n")
    r = read_reply(sock, head_only=(method == b"HEAD"))
    if r is None or r.status != want_status:
        good, detail = False, (i, path, r and r.status)
        break
    if path == "/mid.bin" and method == b"GET" and want_status == 200 and r.body != mid:
        good, detail = False, (i, "mid.bin differs")
        break
    if path == "/hello.txt" and method == b"GET" and r.body != b"Hello, file!\n":
        good, detail = False, (i, "hello differs")
        break
check("%s: %d requests on one kept-alive connection (files, 404, 301, 405, HEAD, range) all framed correctly" % (kind, len(seq)), good, detail)
sock.close()

# pipelined: two requests in one write, answered in order
sock = connect(port, **kw)
sock.sendall(b"GET /hello.txt HTTP/1.1\r\nHost: x\r\n\r\nGET /mid.bin HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
a, b = read_reply(sock), read_reply(sock)
check("%s: two pipelined requests answered in order" % kind, a and b and a.body == b"Hello, file!\n" and b.body == mid)
sock.close()

# Connection: close and HTTP/1.0
sock = connect(port, **kw)
sock.sendall(b"GET /hello.txt HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
r = read_reply(sock)
sock.settimeout(3)
try:
    eof = sock.recv(10) == b""
except (socket.timeout, ConnectionError):
    eof = False
check("%s: Connection: close on a file is honoured (server closes)" % kind, r.status == 200 and eof)
sock.close()
sock = connect(port, **kw)
sock.sendall(b"GET /hello.txt HTTP/1.0\r\n\r\n")
r = read_reply(sock)
check("%s: HTTP/1.0 request served, Content-Length present" % kind, r and r.status == 200 and r.body == b"Hello, file!\n" and r.h("content-length") == "13")
sock.close()

# --- 4. a client that quits mid-download must not hurt the server ---
for i in range(5):
    sock = connect(port, **kw)
    sock.sendall(("GET /" + BIG + " HTTP/1.1\r\nHost: x\r\n\r\n").encode())
    sock.recv(1000)
    sock.close() if i % 2 else sock.shutdown(socket.SHUT_RDWR)
    sock.close()
time.sleep(0.2)
r = get(port, "/mid.bin", **kw)
check("%s: five clients that abandon a big download mid-stream; the server carries on" % kind, r and r.body == mid)

# a stalled reader does not stop the others
slow = connect(port, **kw)
slow.sendall(("GET /" + BIG + " HTTP/1.1\r\nHost: x\r\n\r\n").encode())
slow.recv(100)
t0 = time.time()
r = get(port, "/mid.bin", **kw)
r2 = get(port, "/hello.txt", **kw)
check("%s: a client that stops reading a big file does not block other requests" % kind,
      r and r2 and r.body == mid and r2.status == 200 and time.time() - t0 < 5, time.time() - t0)
slow.close()

# --- 5. concurrent clients ---
N = 24
results = []
lock = threading.Lock()


def worker(i):
    try:
        out = []
        sock = connect(port, **kw)
        for j in range(6):
            which = (i + j) % 4
            if which == 0:
                path, want = "/mid.bin", hashlib.sha256(mid).hexdigest()
            elif which == 1:
                path, want = "/hello.txt", hashlib.sha256(b"Hello, file!\n").hexdigest()
            elif which == 2:
                path, want = "/data.json", filesha("data.json")
            else:
                path, want = "/" + BIG, big_sha
            if which == 3 and i % 3 != 0:
                path, want = "/mid.bin", hashlib.sha256(mid).hexdigest()
            sock.sendall(("GET %s HTTP/1.1\r\nHost: x\r\n\r\n" % path).encode())
            r = read_reply(sock, keep_body=False)
            out.append(r is not None and r.status == 200 and r.sha256 == want)
        sock.close()
        with lock:
            results.append(all(out))
    except Exception as e:  # noqa
        with lock:
            results.append(repr(e))


t0 = time.time()
threads = [threading.Thread(target=worker, args=(i,)) for i in range(N)]
for th in threads:
    th.start()
for th in threads:
    th.join(120)
bad_ones = [x for x in results if x is not True]
check("%s: %d concurrent keep-alive clients x 6 requests (a few of them %d MiB): every body checksum-exact (%.1f s)" % (kind, N, big_size >> 20, time.time() - t0),
      len(results) == N and not bad_ones, bad_ones[:3], len(results))
if rss_kb(pid) >= 0:
    check("%s: server RSS after the concurrent run is bounded (%d MB < 400 MB)" % (kind, rss_kb(pid) // 1024), rss_kb(pid) < 400 * 1024)

# HEAD parity under load: GET and HEAD on many files concurrently
r = get(port, "/hello.txt", **kw)
check("%s: server answers normally after all of it" % kind, r and r.status == 200 and r.body == b"Hello, file!\n")
finish()
