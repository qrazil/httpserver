"""Directory listing, dotfile policy, --index, --cache.
Usage: static_policy.py A B C ROOT
  A: --listing   B: --listing --dotfiles --index hello.txt   C: --cache 3600 (no listing)"""
import html
import json
import os
import sys
import urllib.parse

from static_common import *

A, B, C, root = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]


def expected_entries(rel, dotfiles):
    d = os.path.join(root, rel)
    dirs, files = [], []
    for name in os.listdir(d):
        p = os.path.join(d, name)
        if (name.startswith(".") and not dotfiles) or os.path.islink(p):
            continue
        if os.path.isdir(p):
            dirs.append(name)
        elif os.path.isfile(p):
            files.append(name)
    return sorted(dirs), sorted(files)


# --- listing off (C): a directory with no index is 403 with a small body; with an index it is served ---
r = get(C, "/noindex/")
check("listing off: /noindex/ -> 403, small body, lists nothing", r.status == 403 and len(r.body) < 200 and b"one.txt" not in r.body, r.status)
r = get(C, "/emptydir/")
check("listing off: an empty directory -> 403", r.status == 403)
r = get(C, "/")
check("listing off: / serves index.html", r.status == 200 and b"<h1>home</h1>" in r.body)
r = get(C, "/withindex/")
check("a directory's index.html wins", r.status == 200 and r.body == b"<h1>with index</h1>\n")
r = get(C, "/noindex/?json")
check("listing off: ?json does not turn it on", r.status == 403)
r = get(C, "/sub", method=b"HEAD")
check("a directory without the slash redirects before it decides about listing", r.status == 301 and r.h("location") == "/sub/")

# --- listing on (A): HTML ---
r = get(A, "/noindex/")
body = r.body.decode()
check("listing on: HTML 200, text/html; charset=utf-8, nosniff, CSP, no-cache",
      r.status == 200 and r.h("content-type") == "text/html; charset=utf-8" and r.h("x-content-type-options") == "nosniff"
      and "default-src 'none'" in (r.h("content-security-policy") or "") and r.h("content-length") == str(len(r.body)), r.headers)
check("HTML listing names the directory and the files, with relative links", "Index of /noindex/" in body and 'href="./one.txt"' in body and 'href="./two.json"' in body)
check("HTML listing escapes names (&lt;b&gt;x&amp;y.txt) and URL-quotes links",
      "&lt;b&gt;x&amp;y.txt" in body and "<b>x" not in body and 'href="./%3Cb%3Ex%26y.txt"' in body, body[-400:])
r2 = get(A, "/noindex/%3Cb%3Ex%26y.txt")
check("the quoted link of the oddly named file works", r2.status == 200 and r2.body == b"html-special name\n")
r = get(A, "/sub/")
check("sub-directory listing links up with ../ and lists subdirs with a trailing slash", 'href="../"' in r.body.decode() and 'href="./deep/"' in r.body.decode())
r = get(A, "/")
check("listing on: / still prefers index.html", r.status == 200 and b"<h1>home</h1>" in r.body)
r = get(A, "/emptydir/")
check("listing on: empty directory -> 200 with an empty list", r.status == 200 and b'href=".//' not in r.body and b'href="./' not in r.body)
r = get(A, "/", method=b"HEAD")
check("HEAD /noindex/ listing: no body, Content-Length of the GET",
      (lambda h, g: h.status == 200 and h.body == b"" and h.h("content-length") == g.h("content-length"))(get(A, "/noindex/", method=b"HEAD"), get(A, "/noindex/")))

# --- listing on: JSON, by ?json and by Accept ---
for how, target, extra in [("?json", "/noindex/?json", b""), ("Accept: application/json", "/noindex/", b"Accept: application/json\r\n"),
                           ("?format=json", "/noindex/?format=json", b"")]:
    r = get(A, target, extra)
    ok_json = False
    try:
        doc = json.loads(r.body)
        names = [e["name"] for e in doc["entries"]]
        ok_json = (r.status == 200 and r.h("content-type") == "application/json; charset=utf-8"
                   and doc["path"] == "/noindex/" and doc["truncated"] is False
                   and names == ["<b>x&y.txt", "one.txt", "two.json"] and all(e["type"] == "file" and "size" in e and "mtime" in e for e in doc["entries"]))
    except Exception as e:  # noqa
        pass
    check("JSON listing via %s: valid, exact names, sizes and mtimes" % how, ok_json, r.status, r.body[:200])
r = get(A, "/noindex/", b"Accept: text/html,application/xhtml+xml,application/json;q=0.9\r\n")
check("a browser's Accept (text/html first) gets HTML", r.h("content-type").startswith("text/html"))
r = get(A, "/noindex/", b"Accept: */*\r\n")
check("Accept: */* gets HTML", r.h("content-type").startswith("text/html"))
r = get(A, "/noindex/?json")
check("JSON listing varies on Accept", "accept" in (r.h("vary") or "").lower())
doc = json.loads(get(A, "/sub/?json").body)
dirs, files = expected_entries("sub", False)
check("JSON listing of /sub/ equals the file system (dirs first, then files, each sorted)",
      [e["name"] for e in doc["entries"]] == dirs + files and [e["type"] for e in doc["entries"]] == ["dir"] * len(dirs) + ["file"] * len(files), doc)
r = get(A, "/?json")
check("/?json with an index file serves the index file", r.status == 200 and b"<h1>home</h1>" in r.body)

# --- listing hides what must be hidden ---
listing_names = []
for target in ["/sub/?json", "/noindex/?json"]:
    listing_names += [e["name"] for e in json.loads(get(A, target).body)["entries"]]
check("listing A never shows .env (dotfile) in /sub/", ".env" not in listing_names and "link-deep" not in listing_names, listing_names)

# --- dotfiles hidden by default everywhere, served when asked ---
for target in ["/.hidden", "/.git/config", "/sub/.env", "/.well-known/security.txt"]:
    ra, rb = get(A, target), get(B, target)
    check("dotfiles: %s -> 404 by default, 200 with --dotfiles" % target, ra.status == 404 and b"SECRET" not in ra.body and rb.status == 200,
          ra.status, rb.status)
check("dotfiles: a hidden file's 404 is byte-identical to a missing file's (no existence oracle)",
      get(A, "/.hidden").body == get(A, "/.hiddenx").body and get(A, "/.hidden").status == get(A, "/.hiddenx").status)
check("dotfiles on: /.hidden content is the file", get(B, "/.hidden").body == b"SECRET-DOTFILE\n")
sub_b = [e["name"] for e in json.loads(get(B, "/sub/?json").body)["entries"]]
check("dotfiles on: listing shows .env; still hides symlinks", ".env" in sub_b and "link-deep" not in sub_b, sub_b)
for target in ["/link-file", "/link-up/secret.txt", "/link-inside", "/sub/link-deep", "/link-abs", "/link-dir-inside/a.txt"]:
    r = get(B, target)
    check("symlinks are refused even with --dotfiles: %s -> 403" % target, r.status == 403 and b"SECRET" not in r.body, r.status)
r = get(B, "/../secret.txt")
check("--dotfiles does not weaken `..`", r.status == 400)

# --- --index NAME (B: hello.txt) ---
r = get(B, "/")
check("--index hello.txt: / serves hello.txt", r.status == 200 and r.body == b"Hello, file!\n" and r.h("content-type").startswith("text/plain"))
r = get(B, "/withindex/")
check("--index hello.txt: a directory without hello.txt lists (listing on)", r.status == 200 and b"index.html" in r.body and b"other.txt" in r.body)

# --- --cache ---
r = get(C, "/hello.txt")
check("--cache 3600: Cache-Control: public, max-age=3600", r.h("cache-control") == "public, max-age=3600", r.h("cache-control"))
r = get(A, "/hello.txt")
check("default: Cache-Control: no-cache (always revalidate)", r.h("cache-control") == "no-cache", r.h("cache-control"))
r = get(C, "/hello.txt", b"If-None-Match: *\r\n")
check("304 repeats Cache-Control", r.status == 304 and r.h("cache-control") == "public, max-age=3600")
r = get(C, "/nope")
check("errors are not cacheable-by-accident: a 404 carries no max-age", "max-age" not in (r.h("cache-control") or ""))

# --- errors: small bodies, right headers, nothing reflected ---
for srv, target, status in [(C, "/nope", 404), (C, "/.hidden", 404), (C, "/link-file", 403), (C, "/noindex/", 403), (C, "/%zz", 400), (C, "/../x", 400)]:
    r = get(srv, target)
    check("%s -> %d: text/plain, small body, no echo of the request" % (target, status),
          r.status == status and r.h("content-type").startswith("text/plain") and len(r.body) < 120
          and r.h("content-length") == str(len(r.body)) and b"nope" not in r.body and b"zz" not in r.body, r.status, r.body)
r = get(C, "/<script>alert(1)</script>")
check("a hostile path is not reflected into the 404 body", r.status == 404 and b"script" not in r.body)
r = get(C, "/hello.txt", method=b"POST")
check("405 carries Allow: GET, HEAD, OPTIONS", r.status == 405 and r.h("allow") == "GET, HEAD, OPTIONS")
finish()
