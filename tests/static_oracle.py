"""Behaviour checks against oracles: Python's http.server (status, body,
length, type, redirects), Python's mimetypes (content types), curl (ranges,
resume, conditional requests, redirects).
Usage: static_oracle.py OURS-PORT PYTHON-PORT ROOT"""
import hashlib
import mimetypes
import os
import sys
import tempfile
import time

from static_common import *

ours, theirs, root = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
O = "http://127.0.0.1:%d" % ours


def sha(path):
    return hashlib.sha256(open(os.path.join(root, path), "rb").read()).hexdigest()


def base(ct):
    return (ct or "").split(";")[0].strip().lower()


# --- 1. the same files as python's http.server: status, body, length ---
paths = ["hello.txt", "data.json", "style.css", "app.js", "page.htm", "notes.md", "icon.svg",
         "pic.png", "pic.jpg", "pic.gif", "doc.pdf", "table.csv", "feed.xml", "blob.bin",
         "noext", "empty.txt", "UPPER.TXT", "sp%20ace.txt", "caf%C3%A9/%C3%BCn%C3%AF.txt",
         "sub/a.txt", "sub/deep/b.txt", "a%26b%3Dc%3Bd.txt", "mid.bin", "withindex/other.txt"]
mism = []
for p in paths:
    a = get(ours, "/" + p)
    b = get(theirs, "/" + p)
    if a is None or b is None or a.status != b.status or a.body != b.body \
            or a.h("content-length") != b.h("content-length"):
        mism.append((p, a and a.status, b and b.status))
check("same status, body and Content-Length as python http.server (%d files)" % len(paths), not mism, mism)

# HEAD
mism = []
for p in paths:
    a = get(ours, "/" + p, method=b"HEAD")
    b = get(theirs, "/" + p, method=b"HEAD")
    if a is None or b is None or a.status != b.status or a.body != b"" \
            or a.h("content-length") != b.h("content-length"):
        mism.append((p, a and a.status, b and b.status))
check("HEAD: same status and Content-Length as python http.server, no body", not mism, mism)

# missing, and directory without slash, and index
for target, name in [("/nope.txt", "404 for a missing file"), ("/nodir/x", "404 for a missing directory")]:
    a, b = get(ours, target), get(theirs, target)
    check("python http.server agrees: " + name, a and b and a.status == b.status == 404, a and a.status, b and b.status)
a, b = get(ours, "/sub"), get(theirs, "/sub")
check("/sub -> 301 /sub/ like python http.server",
      a and b and a.status == b.status == 301 and a.h("location") == b.h("location") == "/sub/",
      a and (a.status, a.h("location")), b and (b.status, b.h("location")))
a, b = get(ours, "/withindex/"), get(theirs, "/withindex/")
check("directory with index.html serves it, like python http.server",
      a and b and a.status == b.status == 200 and a.body == b.body)
a = get(ours, "/")
check("/ serves index.html", a and a.status == 200 and a.body == open(os.path.join(root, "index.html"), "rb").read())
check("POST -> 405 with Allow, like python http.server's non-GET refusal",
      (lambda r: r and r.status == 405 and "GET" in (r.h("allow") or ""))(get(ours, "/hello.txt", method=b"POST")))
for m in (b"PUT", b"DELETE", b"PATCH", b"TRACE", b"CONNECT"):
    r = get(ours, "/hello.txt", method=m)
    check("%s -> 405, a small body, no file" % m.decode(), r and r.status in (405, 400, 501) and len(r.body) < 200 and b"Hello, file" not in r.body, r and r.status)
r = get(ours, "/hello.txt", method=b"OPTIONS")
check("OPTIONS -> 204 with Allow", r and r.status == 204 and "GET" in (r.h("allow") or ""))

# If-Modified-Since: python's server answers 304 for a date at/after mtime
mtime = os.path.getmtime(os.path.join(root, "hello.txt"))
future = time.strftime("%a, %d %b %Y %H:%M:%S GMT", time.gmtime(mtime + 3600))
past = time.strftime("%a, %d %b %Y %H:%M:%S GMT", time.gmtime(mtime - 3600))
a = get(ours, "/hello.txt", b"If-Modified-Since: " + future.encode() + b"\r\n")
b = get(theirs, "/hello.txt", b"If-Modified-Since: " + future.encode() + b"\r\n")
check("If-Modified-Since (later date): 304 like python http.server", a and b and a.status == b.status == 304 and a.body == b"", a and a.status, b and b.status)
a = get(ours, "/hello.txt", b"If-Modified-Since: " + past.encode() + b"\r\n")
check("If-Modified-Since (earlier date): 200 with the body", a and a.status == 200 and a.body == b"Hello, file!\n")

# --- 2. content types vs mimetypes ---
exact = {"index.html": "text/html; charset=utf-8", "page.htm": "text/html; charset=utf-8",
         "data.json": "application/json; charset=utf-8", "style.css": "text/css; charset=utf-8",
         "app.js": "text/javascript; charset=utf-8", "mod.mjs": "text/javascript; charset=utf-8",
         "hello.txt": "text/plain; charset=utf-8", "notes.md": "text/markdown; charset=utf-8",
         "feed.xml": "application/xml; charset=utf-8", "icon.svg": "image/svg+xml",
         "pic.png": "image/png", "pic.jpg": "image/jpeg", "pic.gif": "image/gif",
         "pic.webp": "image/webp", "doc.pdf": "application/pdf", "mod.wasm": "application/wasm",
         "font.woff2": "font/woff2", "table.csv": "text/csv; charset=utf-8",
         "noext": "application/octet-stream", "weird.unknownext": "application/octet-stream",
         "blob.bin": "application/octet-stream", "UPPER.TXT": "text/plain; charset=utf-8"}
wrong = []
for name, want in exact.items():
    r = get(ours, "/" + name)
    if not r or r.h("content-type") != want:
        wrong.append((name, r and r.h("content-type"), want))
check("Content-Type by extension (%d files; text types carry charset=utf-8)" % len(exact), not wrong, wrong)

alias = {"text/javascript": {"application/javascript", "text/javascript"},
         "application/xml": {"application/xml", "text/xml"},
         "image/vnd.microsoft.icon": {"image/x-icon", "image/vnd.microsoft.icon"},
         "text/markdown": {"text/markdown", "text/x-markdown", None},
         "font/woff2": {"font/woff2", "application/font-woff2"},
         "text/csv": {"text/csv", "application/csv"}}
diffs = []
for name in ["hello.txt", "data.json", "style.css", "app.js", "page.htm", "icon.svg", "pic.png", "pic.jpg",
             "pic.gif", "pic.webp", "doc.pdf", "mod.wasm", "feed.xml", "favicon.ico", "table.csv", "notes.md"]:
    r = get(ours, "/" + name)
    theirs_type, _ = mimetypes.guess_type(name)
    got = base(r.h("content-type")) if r else None
    if theirs_type is None:
        continue
    if got != theirs_type and theirs_type not in alias.get(got, set()):
        diffs.append((name, got, theirs_type))
check("Content-Type agrees with python mimetypes (up to well-known aliases)", not diffs, diffs)
r = get(ours, "/UPPER.TXT")
check("extension match is case-insensitive", r and base(r.h("content-type")) == "text/plain")

# --- 3. headers on a file ---
r = get(ours, "/data.json")
check("200 has Content-Length, ETag, Last-Modified, Accept-Ranges: bytes, nosniff, Date",
      r and r.h("content-length") == str(len(r.body)) and r.h("etag") and r.h("last-modified") and r.h("accept-ranges") == "bytes"
      and r.h("x-content-type-options") == "nosniff" and r.h("date"), r and r.headers)
etag, lm = r.h("etag"), r.h("last-modified")
check("ETag is a quoted strong validator", etag.startswith('"') and etag.endswith('"') and not etag.startswith("W/"), etag)
check("Last-Modified is an IMF-fixdate (GMT)", lm.endswith(" GMT") and len(lm) == 29, lm)

# --- 4. curl as oracle: conditional requests ---
code, out = curl("-D", "-", "-o", "/dev/null", "-w", "%{http_code}", "-H", "If-None-Match: " + etag, O + "/data.json")
check("curl If-None-Match: matching ETag -> 304", code == 0 and out.decode().endswith("304"), out[-200:])
code, out = curl("-o", "/dev/null", "-w", "%{http_code}", "-H", 'If-None-Match: "other", ' + etag, O + "/data.json")
check("If-None-Match: a list containing the ETag -> 304", out == b"304", out)
code, out = curl("-o", "/dev/null", "-w", "%{http_code}", "-H", 'If-None-Match: "other"', O + "/data.json")
check("If-None-Match: another ETag -> 200", out == b"200", out)
code, out = curl("-o", "/dev/null", "-w", "%{http_code}", "-H", "If-None-Match: *", O + "/data.json")
check("If-None-Match: * -> 304", out == b"304", out)
code, out = curl("-o", "/dev/null", "-w", "%{http_code}", "-H", "If-None-Match: W/" + etag, O + "/data.json")
check("If-None-Match uses weak comparison (W/ prefix) -> 304", out == b"304", out)
code, out = curl("-o", "/dev/null", "-w", "%{http_code}", "-H", "If-Modified-Since: " + lm, O + "/data.json")
check("If-Modified-Since: Last-Modified -> 304", out == b"304", out)
code, out = curl("-o", "/dev/null", "-w", "%{http_code}", "-H", "If-None-Match: \"other\"", "-H", "If-Modified-Since: " + lm, O + "/data.json")
check("If-None-Match wins over If-Modified-Since (RFC 9110 13.1.3)", out == b"200", out)
code, out = curl("-o", "/dev/null", "-w", "%{http_code}", "-H", "If-Modified-Since: garbage", O + "/data.json")
check("unparsable If-Modified-Since is ignored -> 200", out == b"200", out)
code, out = curl("-o", "/dev/null", "-w", "%{http_code}", "-z", lm, O + "/data.json")
check("curl -z DATE (its own time condition) -> 304", out == b"304", out)
r = get(ours, "/data.json", b"If-None-Match: " + etag.encode() + b"\r\n")
check("304 has no body, carries ETag/Last-Modified, no Content-Type body claim",
      r.status == 304 and r.body == b"" and r.h("etag") == etag and r.h("last-modified") == lm, r.headers)
r = get(ours, "/data.json", b"If-None-Match: " + etag.encode() + b"\r\n", method=b"HEAD")
check("HEAD + matching If-None-Match -> 304", r.status == 304)
r = get(ours, "/data.json", b"If-Match: \"nope\"\r\n")
check("If-Match: another ETag -> 412", r.status == 412)
r = get(ours, "/data.json", b"If-Match: " + etag.encode() + b"\r\n")
check("If-Match: the ETag -> 200", r.status == 200)
r = get(ours, "/data.json", b"If-Unmodified-Since: " + past.encode() + b"\r\n")
check("If-Unmodified-Since: before the file's mtime -> 412", r.status == 412)
r = get(ours, "/data.json", b"If-Unmodified-Since: " + future.encode() + b"\r\n")
check("If-Unmodified-Since: after the file's mtime -> 200", r.status == 200)
r = get(ours, "/nope.txt", b"If-None-Match: *\r\n")
check("a precondition on a missing file is still 404", r.status == 404)

# --- 5. ranges (curl --range as the oracle) ---
full = open(os.path.join(root, "mid.bin"), "rb").read()
n = len(full)
def rng(spec, path="/mid.bin"):
    code, out = curl("-H", "Range: bytes=" + spec, O + path)  # curl exits 0 on 206
    return out
for spec, a, b in [("0-0", 0, 0), ("0-99", 0, 99), ("1000-1999", 1000, 1999), ("5-", 5, n - 1),
                   ("-500", n - 500, n - 1), ("%d-" % (n - 1), n - 1, n - 1),
                   ("100-%d" % (n + 5000), 100, n - 1), ("-%d" % (n + 10), 0, n - 1)]:
    out = rng(spec)
    check("curl --range %s -> exactly those bytes" % spec, out == full[a:b + 1], len(out))
r = get(ours, "/mid.bin", b"Range: bytes=10-19\r\n")
check("206: Content-Range, Content-Length, Accept-Ranges, ETag",
      r.status == 206 and r.h("content-range") == "bytes 10-19/%d" % n and r.h("content-length") == "10"
      and r.h("accept-ranges") == "bytes" and r.h("etag") and r.body == full[10:20], r.headers)
r = get(ours, "/mid.bin", b"Range: bytes=-5\r\n")
check("suffix range Content-Range", r.h("content-range") == "bytes %d-%d/%d" % (n - 5, n - 1, n), r.headers)
for spec in ["%d-" % n, "%d-%d" % (n, n + 10), "-0", "99999999999-"]:
    r = get(ours, "/mid.bin", ("Range: bytes=%s\r\n" % spec).encode())
    check("Range %s -> 416 with Content-Range: bytes */%d" % (spec, n),
          r.status == 416 and r.h("content-range") == "bytes */%d" % n and len(r.body) < 200, r.status, r.headers)
for spec in ["bytes=5-2", "bytes=a-b", "bytes=", "bytes=-", "items=0-5", "bytes=0-5,10-15", "bytes=0-5, 7-9",
             "bytes=--5", "bytes= 5", "bytes=1-2-3", "garbage", "bytes=0x10-0x20", "bytes=+5-9", "bytes=-9223372036854775808"]:
    r = get(ours, "/mid.bin", ("Range: %s\r\n" % spec).encode())
    check("Range %r is ignored or refused cleanly (200 whole file, or 416), never a 5xx or partial" % spec,
          r and ((r.status == 200 and r.body == full) or r.status == 416), r and r.status)
r = get(ours, "/mid.bin", b"Range: bytes=0-9\r\n", method=b"HEAD")
check("HEAD ignores Range: 200 with the full length", r.status == 200 and r.h("content-length") == str(n))
r = get(ours, "/mid.bin", b"Range: bytes=0-9\r\nIf-Range: " + (get(ours, "/mid.bin", method=b"HEAD").h("etag")).encode() + b"\r\n")
check("If-Range with the current ETag: 206", r.status == 206 and len(r.body) == 10)
r = get(ours, "/mid.bin", b"Range: bytes=0-9\r\nIf-Range: \"stale\"\r\n")
check("If-Range with another ETag: the whole file, 200", r.status == 200 and r.body == full)
lm2 = get(ours, "/mid.bin", method=b"HEAD").h("last-modified")
r = get(ours, "/mid.bin", ("Range: bytes=0-9\r\nIf-Range: %s\r\n" % lm2).encode())
check("If-Range with the current Last-Modified: 206", r.status == 206)
r = get(ours, "/mid.bin", b"Range: bytes=0-9\r\nIf-Range: Mon, 01 Jan 2001 00:00:00 GMT\r\n")
check("If-Range with another date: the whole file, 200", r.status == 200 and len(r.body) == n)
r = get(ours, "/empty.txt", b"Range: bytes=0-0\r\n")
check("any range of an empty file -> 416", r.status == 416, r.status)
r = get(ours, "/empty.txt")
check("an empty file: 200, Content-Length: 0", r.status == 200 and r.h("content-length") == "0" and r.body == b"")

# curl resume: a partial file continued with -C -
with tempfile.TemporaryDirectory() as tmp:
    part = os.path.join(tmp, "part")
    open(part, "wb").write(full[:123456])
    code, out = curl("-C", "-", "-o", part, O + "/mid.bin")
    check("curl -C - resumes a partial download to the exact file", code == 0 and open(part, "rb").read() == full, code)
    done = os.path.join(tmp, "done")
    open(done, "wb").write(full)
    code, out = curl("-C", "-", "-o", done, "-w", "%{http_code}", O + "/mid.bin")
    check("curl -C - on a complete file leaves it intact (416 handling differs between curl versions)", code in (0, 33) and open(done, "rb").read() == full, code, out)

# --- 6. redirects and curl -L ---
code, out = curl("-L", O + "/sub")
check("curl -L /sub follows the redirect to the directory (403: no listing by default)",
      code == 0 and out.startswith(b"403 Forbidden"), out[:80])
code, out = curl("-o", "/dev/null", "-w", "%{http_code} %{redirect_url}", O + "/sub")
check("redirect target is absolute-path /sub/ (no host taken from the request)", out.decode() == "301 " + O + "/sub/", out)
code, out = curl("-o", "/dev/null", "-w", "%{http_code} %{redirect_url}", "-H", "Host: evil.example", O + "/sub")
check("a hostile Host header does not reach the Location", "evil" not in out.decode(), out)
code, out = curl("-o", "/dev/null", "-w", "%{http_code} %{redirect_url}", O + "/sub?x=1&y=%20z")
check("the query string survives the directory redirect", out.decode().endswith("/sub/?x=1&y=%20z"), out)
code, out = curl("-o", "/dev/null", "-w", "%{http_code} %{redirect_url}", "--path-as-is", O + "//evil.example/..%2f")
check("//host in the path is never an open redirect", "evil.example" not in out.decode().replace(O, "") or out.decode().startswith("4"), out)
code, out = curl("-o", "/dev/null", "-w", "%{http_code} %{redirect_url}", "--path-as-is", O + "//noindex")
check("//dir redirects to /dir/ on this host, not to a host called dir", out.decode() == "301 " + O + "/noindex/", out)
code, out = curl("-o", "/dev/null", "-w", "%{http_code}", "--path-as-is", O + "/sub/./deep/../a.txt")
check("curl --path-as-is with ../ in the path is refused (400), not resolved", out == b"400", out)
code, out = curl("-o", "/dev/null", "-w", "%{http_code}", O + "/sub/./deep/../a.txt")
check("curl's own dot-segment normalisation reaches the file (200)", out == b"200", out)

# --- 7. HEAD parity with GET across the board ---
bad_parity = []
for p in ["/", "/hello.txt", "/data.json", "/mid.bin", "/empty.txt", "/sub", "/sub/", "/withindex/", "/nope", "/.hidden", "/link-file",
          "/noindex/", "/emptydir/", "/hello.txt?x=1", "/sub/a.txt/"]:
    for extra in [b"", b"If-None-Match: *\r\n"]:
        g = get(ours, p, extra)
        h = get(ours, p, extra, method=b"HEAD")
        if g is None or h is None or g.status != h.status or h.body != b"":
            bad_parity.append((p, extra, g and g.status, h and h.status))
            continue
        for name in ("content-type", "etag", "last-modified", "accept-ranges", "cache-control", "location", "allow", "content-range", "vary"):
            if g.h(name) != h.h(name):
                bad_parity.append((p, name, g.h(name), h.h(name)))
        # Content-Length: equal for anything with a body; for a 304 neither has one
        if g.status != 304 and g.status != 206 and g.h("content-length") != h.h("content-length"):
            bad_parity.append((p, "content-length", g.h("content-length"), h.h("content-length")))
check("HEAD parity: same status and headers as GET, never a body (%d request shapes)" % 30, not bad_parity, bad_parity[:3])
finish()
