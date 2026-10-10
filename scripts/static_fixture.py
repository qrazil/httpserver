"""Build the disposable tree the static-file tests serve:  OUTER/root is the
served directory; everything else under OUTER is OUTSIDE it and must never be
sent.  Usage: static_fixture.py OUTER"""
import os
import struct
import sys
import zlib

outer = sys.argv[1]
root = os.path.join(outer, "root")


def put(rel, data, base=root):
    path = os.path.join(base, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data if isinstance(data, bytes) else data.encode())


def png():
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + \
            struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)) + \
        chunk(b"IDAT", zlib.compress(b"\x00\xff\x00\x00")) + chunk(b"IEND", b"")


# --- outside the root: must never be served ---
put("secret.txt", "SECRET-OUTSIDE-ROOT\n", outer)
put("root-evil/x.txt", "SECRET-SIBLING-PREFIX\n", outer)
put("outer-index.html", "SECRET-OUTER-INDEX\n", outer)

# --- served ---
put("index.html", "<!doctype html><title>home</title><h1>home</h1>\n")
put("hello.txt", "Hello, file!\n")
put("data.json", '{"name": "fixture", "n": [1, 2, 3]}\n')
put("style.css", "body { color: #123456 }\n")
put("app.js", "console.log('app');\n")
put("mod.mjs", "export const x = 1;\n")
put("page.htm", "<p>htm</p>\n")
put("notes.md", "# notes\n")
put("icon.svg", '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>\n')
put("pic.png", png())
put("pic.jpg", b"\xff\xd8\xff\xe0" + b"jpegish" * 10)
put("pic.gif", b"GIF89a" + b"\x01\x00\x01\x00\x00\x00\x00;")
put("pic.webp", b"RIFF\x04\x00\x00\x00WEBP")
put("favicon.ico", b"\x00\x00\x01\x00" + b"\x00" * 20)
put("font.woff2", b"wOF2" + b"\x00" * 30)
put("mod.wasm", b"\x00asm\x01\x00\x00\x00")
put("doc.pdf", b"%PDF-1.4\n%%EOF\n")
put("table.csv", "a,b\n1,2\n")
put("feed.xml", "<?xml version='1.0'?><r/>\n")
put("blob.bin", bytes(range(256)) * 4)
put("noext", "no extension\n")
put("weird.unknownext", "unknown\n")
put("UPPER.TXT", "upper-case extension\n")
put("sp ace.txt", "space in name\n")
put("café/ünï.txt", "unicode name\n")
put("empty.txt", b"")
put("%2e%2e", "I am a file literally named percent-2e-percent-2e\n")
put("a&b=c;d.txt", "punctuation\n")
put("sub/a.txt", "sub a\n")
put("sub/deep/b.txt", "deep b\n")
put("withindex/index.html", "<h1>with index</h1>\n")
put("withindex/other.txt", "other\n")
put("noindex/one.txt", "1\n")
put("noindex/two.json", "{}\n")
put("noindex/<b>x&y.txt", "html-special name\n")
os.makedirs(os.path.join(root, "emptydir"), exist_ok=True)

# --- hidden by the dotfile policy ---
put(".hidden", "SECRET-DOTFILE\n")
put(".git/config", "SECRET-DOTGIT\n")
put("sub/.env", "SECRET-DOTENV\n")
put(".well-known/security.txt", "dot directory content\n")

# --- links: none may be served or followed ---
os.symlink("../secret.txt", os.path.join(root, "link-file"))
os.symlink("..", os.path.join(root, "link-up"))
os.symlink("../root-evil", os.path.join(root, "link-sibling"))
os.symlink("hello.txt", os.path.join(root, "link-inside"))
os.symlink("sub", os.path.join(root, "link-dir-inside"))
os.symlink("../../secret.txt", os.path.join(root, "sub", "link-deep"))
os.symlink("/etc/passwd", os.path.join(root, "link-abs"))
os.symlink("nowhere", os.path.join(root, "link-dangling"))
os.symlink("link-loop", os.path.join(root, "link-loop"))

# --- not a regular file ---
os.mkfifo(os.path.join(root, "fifo.txt"))

# --- big ones (random, so a checksum means something) ---
def big(rel, mib):
    with open(os.path.join(root, rel), "wb") as f:
        for _ in range(mib):
            f.write(os.urandom(1 << 20))
        f.write(os.urandom(777))  # not a multiple of the chunk size

big("big.bin", int(sys.argv[2]) if len(sys.argv) > 2 else 64)
big("mid.bin", 3)
big("tls.bin", 12)  # the TLS stack is the slow part; https streams this one
