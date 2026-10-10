"""Path-traversal corpus + random fuzz + malformed request lines. Property:
nothing outside the root (or hidden, or behind a link) is ever sent, every
200 body is a file that IS meant to be served, no 5xx, no empty reply, and the
server is alive at the end.
Usage: static_fuzz.py PORT ROOT [SEED]"""
import hashlib
import os
import random
import sys

from static_common import *

port, root = int(sys.argv[1]), sys.argv[2]
seed = int(sys.argv[3]) if len(sys.argv) > 3 else 20261010
rnd = random.Random(seed)

SENTINELS = [b"SECRET-OUTSIDE-ROOT", b"SECRET-SIBLING-PREFIX", b"SECRET-OUTER-INDEX", b"SECRET-DOTFILE",
             b"SECRET-DOTGIT", b"SECRET-DOTENV", b"root:x:0:0", b"root:*:0:0"]

# bodies the server is allowed to send with a 200: regular, visible, un-linked files
allowed = set()
for dirpath, dirs, files in os.walk(root):
    dirs[:] = [d for d in dirs if not d.startswith(".") and not os.path.islink(os.path.join(dirpath, d))]
    for f in files:
        p = os.path.join(dirpath, f)
        if f.startswith(".") or os.path.islink(p) or not os.path.isfile(p) or os.path.getsize(p) > (1 << 20):
            continue
        allowed.add(hashlib.sha256(open(p, "rb").read()).hexdigest())
allowed.add(hashlib.sha256(b"").hexdigest())

problems = []
count = 0
statuses = {}


def probe(target, label=None, extra=b"", method=b"GET", expect=None):
    """Send `target` verbatim. Records any violation."""
    global count
    count += 1
    t = target if isinstance(target, bytes) else target.encode("latin-1")
    r = get(port, t, extra, method=method)
    tag = label or repr(t[:120])
    if r is None:
        problems.append((tag, "no reply"))
        return None
    statuses[r.status] = statuses.get(r.status, 0) + 1
    if r.status >= 500:
        problems.append((tag, "status %d" % r.status))
    for s in SENTINELS:
        if s in r.body:
            problems.append((tag, "LEAKED " + s.decode()))
    listing_ok = os.environ.get("FUZZ_LISTING") and (r.h("content-type") or "").startswith("text/html") and b"Index of /" in r.body
    if r.status == 200 and method == b"GET" and not listing_ok and hashlib.sha256(r.body).hexdigest() not in allowed:
        # a listing or an index would be html; only files are expected here (no --listing)
        problems.append((tag, "200 with a body that is no served file (%d bytes)" % len(r.body)))
    if r.status in (301, 302, 307, 308):
        loc = r.h("location") or ""
        if not loc.startswith("/") or loc.startswith("//") or "\\" in loc or "\r" in loc or "\n" in loc:
            problems.append((tag, "unsafe Location " + repr(loc)))
    if expect is not None and r.status not in expect:
        problems.append((tag, "status %d, wanted one of %s" % (r.status, expect)))
    return r


# --- 1. named attacks with a required outcome ---
NOT_SERVED = (400, 403, 404)
named = [
    ("/../secret.txt", (400,)), ("/..", (400,)), ("/../", (400,)), ("/sub/../../secret.txt", (400,)),
    ("/%2e%2e/secret.txt", (400,)), ("/%2E%2E/secret.txt", (400,)), ("/.%2e/secret.txt", (400,)),
    ("/%2e./secret.txt", (400,)), ("/%2e%2e%2fsecret.txt", (400,)), ("/..%2fsecret.txt", (400,)),
    ("/sub/..%2f..%2fsecret.txt", (400,)), ("/..%5csecret.txt", (400,)), ("/..\\secret.txt", (400,)),
    ("/%5c..%5csecret.txt", (400,)), ("/sub%2f..%2f..%2fsecret.txt", (400,)),
    ("/..%00/secret.txt", (400,)), ("/%00", (400,)), ("/hello.txt%00.png", (400,)), ("/hello.txt\x00", (400, 404)),
    ("/%2e%2e%00/secret.txt", (400,)), ("/root-evil/x.txt", NOT_SERVED), ("/../root-evil/x.txt", (400,)),
    ("/%2e%2e/root-evil/x.txt", (400,)), ("/sub/%2e%2e/%2e%2e/root-evil/x.txt", (400,)),
    ("//etc/passwd", NOT_SERVED), ("/etc/passwd", (404,)), ("/%2fetc%2fpasswd", (400,)), ("/%2Fetc/passwd", (400,)),
    ("/\\etc\\passwd", (400,)), ("/C:\\Windows\\win.ini", (400, 404)), ("/c:/secret.txt", (404,)),
    ("/%252e%252e/secret.txt", (404,)), ("/%252e%252e%252fsecret.txt", (404,)), ("/%25252e%25252e/", (404,)),
    ("/..;/secret.txt", (400, 404)), ("/sub/..;/..;/secret.txt", (404,)), ("/....//secret.txt", (404,)),
    ("/.../secret.txt", (404,)), ("/%c0%ae%c0%ae/secret.txt", (400, 404)), ("/%c0%af", (400, 404)),
    ("/%ef%bc%8e%ef%bc%8e/secret.txt", (400, 404)), ("/%e2%80%a5/secret.txt", (400, 404)),
    ("/%u002e%u002e/secret.txt", (400, 404)), ("/%2e%2e;/secret.txt", (400, 404)),
    ("/.hidden", (404,)), ("/%2ehidden", (404,)), ("/.git/config", (404,)), ("/.git/", (404,)), ("/.git", (404,)),
    ("/%2egit/config", (404,)), ("/sub/.env", (404,)), ("/sub/%2eenv", (404,)), ("/.HIDDEN", (404,)),
    ("/.well-known/security.txt", (404,)), ("/.", (200, 301, 403, 404)),
    ("/link-file", (403,)), ("/link-up/secret.txt", (403,)), ("/link-up/", (403,)), ("/link-up", (403,)),
    ("/link-sibling/x.txt", (403,)), ("/link-abs", (403,)), ("/link-inside", (403,)),
    ("/link-dir-inside/a.txt", (403,)), ("/sub/link-deep", (403,)), ("/link-dangling", (403,)),
    ("/link-loop", (403,)), ("/link-up/root/link-up/secret.txt", (403,)), ("/link-up/root-evil/x.txt", (403,)),
    ("/link-file/", (403,)), ("/link-file/x", (403,)), ("/link-up/%2e%2e/secret.txt", (400,)),
    ("/fifo.txt", (404,)), ("/hello.txt/", (404,)), ("/hello.txt/x", (404,)), ("/hello.txt/..", (400,)),
    ("/%", (400,)), ("/%2", (400,)), ("/%zz", (400,)), ("/%g0", (400,)), ("/hello%", (400,)),
    ("/%0d%0aSet-Cookie:x=1", (400,)), ("/%0a", (400,)), ("/%09", (400,)), ("/%1f", (400,)), ("/%7f", (400,)),
    ("/%00hello.txt", (400,)), ("/hello.txt?../../secret.txt", (200,)), ("/hello.txt#../../secret.txt", (200, 400, 404)),
    ("/sub?/../../secret.txt", (301,)), ("/?../secret.txt", (200, 403, 404)),
    ("http://127.0.0.1/../secret.txt", (400, 404)), ("http://evil.example/hello.txt", (200, 400, 404)),
    ("//evil.example", (403, 404)), ("///", (200, 403, 404)), ("/////etc/passwd", (404,)), ("/.//.//.//hello.txt", (200,)),
    ("/./hello.txt", (200,)), ("/sub/./a.txt", (200,)), ("/sub//a.txt", (200,)), ("/sub/a.txt/.", (404, 200)),
]
for target, expect in named:
    r = probe(target, expect=expect)
    if r is not None and r.status == 200 and target in ("/hello.txt?../../secret.txt",):
        pass
check("%d named traversal / dotfile / symlink / encoding attacks: required status, nothing leaked" % len(named),
      not problems, problems[:6])
named_problems = list(problems)

# --- 2. generated corpus: every escape form at every depth, before and after real names ---
escapes = ["..", "%2e%2e", "%2E%2E", ".%2e", "%2e.", "..%2f", "%2e%2e%2f", "..%5c", "%2e%2e%5c", "..%00", "%2e%2e%00",
           "....", "...", "..;", "%252e%252e", "%c0%ae%c0%ae", "%e0%80%ae%e0%80%ae", "%ef%bc%8e%ef%bc%8e", "..%c0%af", "..%ef%bc%8f",
           "..%u2215", "..%255c", "%2e%2e%252f", "\\..", "..\\", ".\\.", ".\\.\\", "~", "~root", "%7eroot", "$HOME", "%24HOME",
           "*", "?", "%3f", "%23", "%20..", "..%20", " ..", ".. ", "..%09", "..%0a"]
prefixes = ["", "sub/", "sub/deep/", "withindex/", "noindex/", "emptydir/", "caf%C3%A9/", "link-up/", ".git/", "hello.txt/"]
targets_after = ["", "/", "/secret.txt", "/root-evil/x.txt", "/etc/passwd", "/root/hello.txt", "/../secret.txt"]
corpus = []
for pre in prefixes:
    for esc in escapes:
        for post in targets_after:
            corpus.append("/" + pre + esc + post)
for t in corpus:
    probe(t)
check("%d generated traversal targets (escape forms x depths x tails): nothing leaked, no 5xx, valid Location" % len(corpus),
      len(problems) == len(named_problems), problems[len(named_problems):][:6])
mark = len(problems)

# --- 3. random fuzz ---
toks = ["..", ".", "%2e%2e", "%2e", "%2f", "%5c", "%00", "%", "a", "sub", "deep", "hello.txt", "a.txt", "index.html", ".hidden",
        ".git", "link-up", "link-file", "secret.txt", "root-evil", "etc", "passwd", "%252e", "%25", "\\", ";", "?", "&", "=", "#", "~",
        "withindex", "noindex", "emptydir", "data.json", "%41", "%c3%a9", "%ff", "%80", "\x7f", "\x01", "\t", " ", "x" * 300]
nrand = int(os.environ.get("FUZZ_N", "2500"))
for _ in range(nrand):
    n = rnd.randint(1, 9)
    parts = [rnd.choice(toks) for _ in range(n)]
    sep = rnd.choice(["/", "/", "/", "//", "/./", ""])
    t = "/" + sep.join(parts)
    if rnd.random() < 0.2:
        t += "/"
    t = t.replace(" ", "%20") if rnd.random() < 0.7 else t.replace(" ", "+")
    t = t.replace("\t", "%09").replace("\x01", "%01").replace("\x7f", "%7f")
    t = t.replace("#", "%23") if rnd.random() < 0.5 else t
    probe(t, label="fuzz " + repr(t[:100]))
check("%d random targets (seed %d): nothing leaked, no 5xx, every 200 is a served file" % (nrand, seed),
      len(problems) == mark, problems[mark:][:6])
mark = len(problems)

# --- 4. malformed request lines and framing -- must answer, never crash ---
raw = [
    b"GET /hello.txt\r\n\r\n", b"GET /hello.txt HTTP/0.9\r\n\r\n", b"GET /hello.txt HTTP/1.1\r\n\r\n",
    b"GET  /hello.txt  HTTP/1.1\r\nHost: x\r\n\r\n", b"GET\t/hello.txt\tHTTP/1.1\r\nHost: x\r\n\r\n",
    b"GET * HTTP/1.1\r\nHost: x\r\n\r\n", b"GET HTTP/1.1\r\nHost: x\r\n\r\n", b"\r\n\r\n", b"GET\r\n\r\n",
    b"GET /\rHTTP/1.1\r\nHost: x\r\n\r\n",
    b"GET /hello.txt HTTP/9.9\r\nHost: x\r\n\r\n", b"GET /hello.txt HTTP/1.1\r\nHost: x\r\nRange: bytes=0-1\r\nRange: bytes=5-6\r\n\r\n",
    b"GET /hello.txt HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello",
    b"GET /hello.txt HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
    b"GET /hello.txt HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\nContent-Length: 5\r\n\r\nhello",
    b"GET /hello.txt HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n",
    b"POST /hello.txt HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabc",
    b"GET /hello.txt HTTP/1.1\r\nHost: x\r\nIf-None-Match: " + b"a," * 5000 + b"\r\n\r\n",
    b"GET /hello.txt HTTP/1.1\r\nHost: x\r\nRange: bytes=" + b"1-2," * 5000 + b"\r\n\r\n",
    b"GET /hello.txt HTTP/1.1\r\nHost: x\r\nIf-Modified-Since: " + b"9" * 5000 + b"\r\n\r\n",
    b"GET /hello.txt HTTP/1.1\r\nHost: x\r\nIf-Modified-Since: Fri, 99 Foo 9999 99:99:99 GMT\r\n\r\n",
    b"GET /hello.txt HTTP/1.1\r\nHost: x\r\nIf-Modified-Since: Thu, 01 Jan 0001 00:00:00 GMT\r\n\r\n",
    b"GET /hello.txt HTTP/1.1\r\nHost: x\r\nIf-Modified-Since: Fri, 31 Dec 9999 23:59:59 GMT\r\n\r\n",
    b"GET /hello.txt HTTP/1.1\r\nHost: x\r\nIf-Modified-Since: Fri, 31 Dec 99999 23:59:59 GMT\r\n\r\n",
    b"GET /hello.txt HTTP/1.1\r\nHost: x\r\nIf-Range: " + b"\"" * 3000 + b"\r\n\r\n",
    b"GET /hello.txt HTTP/1.1\r\nHost: x\r\nRange: bytes=0-99999999999999999999999999\r\n\r\n",
    b"GET /hello.txt HTTP/1.1\r\nHost: x\r\nRange: bytes=-99999999999999999999999999\r\n\r\n",
    b"GET /hello.txt HTTP/1.1\r\nHost: x\r\nRange: bytes=99999999999999999999999999-\r\n\r\n",
    b"GET /hello.txt HTTP/1.1\r\nHost: x\r\nRange: bytes=9223372036854775807-9223372036854775807\r\n\r\n",
    b"GET /hello.txt HTTP/1.1\r\nHost: x\r\nRange: bytes=0-9223372036854775808\r\n\r\n",
    b"GET /" + b"a" * 100000 + b" HTTP/1.1\r\nHost: x\r\n\r\n",
    b"GET /" + b"a/" * 5000 + b" HTTP/1.1\r\nHost: x\r\n\r\n",
    b"GET /" + b"../" * 5000 + b"secret.txt HTTP/1.1\r\nHost: x\r\n\r\n",
    b"GET /" + b"%2e%2e/" * 5000 + b"secret.txt HTTP/1.1\r\nHost: x\r\n\r\n",
    b"GET /" + b"a" * 300 + b"/x HTTP/1.1\r\nHost: x\r\n\r\n",
    b"GET /hello.txt HTTP/1.1\r\nHost: x\r\n" + b"X-A: b\r\n" * 5000 + b"\r\n",
]
for b in raw:
    count += 1
    r = raw_request(port, b)
    label = repr(b[:90])
    if r is None:
        problems.append((label, "no reply"))
        continue
    statuses[r.status] = statuses.get(r.status, 0) + 1
    if r.status >= 500:
        problems.append((label, "status %d" % r.status))
    for s in SENTINELS:
        if s in r.body:
            problems.append((label, "LEAKED"))
check("%d malformed request lines / headers / framings: every one answered, none 5xx" % len(raw),
      len(problems) == mark, problems[mark:][:6])
mark = len(problems)

# --- 5. invalid UTF-8 and raw control bytes in the request target (an m31 0.3.2 http.read_request trap,
#        guarded in fileserver.m31): 400, and the server lives ---
for t in [b"/\xff", b"/?\xff", b"/hello.txt\xff", b"/\xc0\xaf", b"/\xed\xa0\x80", b"/\xf4\x90\x80\x80", b"/\x80", b"/%ff",
          b"/hello.txt?q=\xfe\xff", b"/\xe2\x82", b"/sub/\xff/..", b"/\x00", b"/\x01", b"/\x7f", b"/\r", b"/\xc3\xa9"]:
    count += 1
    r = raw_request(port, b"GET " + t + b" HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    ok_status = (400, 404, 200)
    if r is None or r.status not in ok_status:
        problems.append((repr(t), "no reply / bad status " + str(r and r.status)))
for t in [b"/\xff", b"/?\xff"]:
    r = raw_request(port, b"GET " + t + b" HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    check("target %r -> 400 (the server survives it)" % t, r is not None and r.status == 400, r and r.status)
for hdr in [b"X-Bin: \xff\xfe\r\n", b"Host: \xff\r\n", b"If-None-Match: \xff\r\n", b"Range: bytes=\xff\r\n", b"Cookie: \x00\r\n"]:
    r = raw_request(port, b"GET /hello.txt HTTP/1.1\r\nHost: x\r\nConnection: close\r\n" + hdr + b"\r\n")
    count += 1
    if r is None or r.status >= 500:
        problems.append((repr(hdr), "no reply / 5xx"))
check("invalid UTF-8 and control bytes in the target and headers: answered, no 5xx",
      len(problems) == mark, problems[mark:][:6])

# --- 6. the server is still there and still right ---
r = get(port, "/hello.txt")
check("server still alive and correct after %d hostile requests" % count, r is not None and r.status == 200 and r.body == b"Hello, file!\n")
print("     status histogram: " + ", ".join("%d:%d" % kv for kv in sorted(statuses.items())), flush=True)
finish()
