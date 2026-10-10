"""Shared pieces of the static-file tests: a tiny reporter and a raw HTTP/1.1
client over a plain socket (or TLS), so a request line goes out EXACTLY as
written -- curl and http.client both normalise things a fuzz corpus needs to
send untouched."""
import hashlib
import os
import socket
import ssl
import subprocess
import sys

PASS = 0
FAIL = 0


def ok(name):
    global PASS
    PASS += 1
    print("ok   " + name, flush=True)


def bad(name, *detail):
    global FAIL
    FAIL += 1
    print("FAIL " + name, flush=True)
    for line in detail:
        print("     " + str(line)[:300], flush=True)


def check(name, cond, *detail):
    if cond:
        ok(name)
    else:
        bad(name, *detail)


def finish():
    print("py-summary %d %d" % (PASS, FAIL), flush=True)
    sys.exit(0 if FAIL == 0 else 1)


def connect(port, host="127.0.0.1", cafile=None, timeout=20):
    # STATIC_TLS_CA: run the whole check file over https instead.
    if cafile is None and os.environ.get("STATIC_TLS_CA"):
        cafile, host = os.environ["STATIC_TLS_CA"], "localhost"
    raw = socket.create_connection((host, port), timeout=timeout)
    raw.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    if cafile:
        ctx = ssl.create_default_context(cafile=cafile)
        return ctx.wrap_socket(raw, server_hostname="localhost")
    return raw


class Reply:
    def __init__(self, status, headers, body, version="HTTP/1.1"):
        self.status = status
        self.headers = headers  # lower-cased name -> value (last wins)
        self.body = body
        self.version = version

    def h(self, name):
        return self.headers.get(name.lower())


def read_reply(sock, head_only=False, keep_body=True):
    """Read one response from `sock` (a socket). Returns Reply, or None on EOF
    before any byte. Body by Content-Length only (this server sends no
    chunked bodies); `head_only` reads no body (HEAD / 304)."""
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(65536)
        if not chunk:
            return None if not buf else Reply(0, {}, buf)
        buf += chunk
    head, _, rest = buf.partition(b"\r\n\r\n")
    lines = head.decode("latin-1").split("\r\n")
    version, status, _ = (lines[0].split(" ", 2) + [""])[:3]
    headers = {}
    for line in lines[1:]:
        name, _, value = line.partition(":")
        headers[name.strip().lower()] = value.strip()
    status = int(status)
    length = int(headers.get("content-length", "0"))
    if head_only or status in (204, 304):
        return Reply(status, headers, b"", version)
    digest_only = not keep_body
    body = b"" if digest_only else rest
    got = len(rest)
    sha = hashlib.sha256(rest)
    while got < length:
        chunk = sock.recv(min(1 << 20, length - got))
        if not chunk:
            break
        got += len(chunk)
        sha.update(chunk)
        if not digest_only:
            body += chunk
    reply = Reply(status, headers, body, version)
    reply.length_read = got
    reply.sha256 = sha.hexdigest()
    return reply


def raw_request(port, request_bytes, head_only=False, **kw):
    """One request on a fresh connection; the reply, or None if the server
    closed without answering."""
    sock = connect(port, **kw)
    try:
        sock.sendall(request_bytes)
        return read_reply(sock, head_only=head_only)
    except (ConnectionError, socket.timeout, ssl.SSLError):
        return None
    finally:
        sock.close()


def get(port, target, extra=b"", method=b"GET", **kw):
    req = method + b" " + (target if isinstance(target, bytes) else target.encode()) + \
        b" HTTP/1.1\r\nHost: x\r\nConnection: close\r\n" + extra + b"\r\n"
    return raw_request(port, req, head_only=(method == b"HEAD"), **kw)


def curl(*args):
    """Run curl, return (exit code, stdout bytes)."""
    p = subprocess.run(["curl", "-sS", "--max-time", "60"] + list(args),
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return p.returncode, p.stdout


def rss_kb(pid):
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)],
                         stdout=subprocess.PIPE).stdout.decode().strip()
    return int(out) if out else -1
