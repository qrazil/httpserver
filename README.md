# `httpserver` -- a "Hello, World!" HTTP/1.1 server, and a static file server

The first real network *server* application written in this language: built
on `lib/http.m31`'s real `Handler`/`serve_conn` machinery (request/response
parsing and writing, framing, keep-alive -- nothing hand-rolled), to exercise
and measure what tonight's green-thread concurrency fix actually bought.
Every accepted connection gets its own green thread and every request gets
the same fixed reply: `200 OK`, `Content-Type: text/plain; charset=utf-8`,
a correct `Content-Length`, body `Hello, World!\n`.

    cargo build                        # the compiler
    bash scripts/build.sh      # ./httpserver
    bash scripts/test.sh       # the tests

    httpserver                         listen on 0.0.0.0:8080
    httpserver --port 9000             listen on 0.0.0.0:9000
    httpserver --host 127.0.0.1        listen on a specific address only
    httpserver --tls-cert chain.pem --tls-key key.pem
                                       serve https instead of http
    httpserver --root ./public         serve the files under ./public
    httpserver --help

Port and host are command-line flags, not environment variables: this
language's standard library has no `getenv` exposed to a `.m31` program
today (`prim`s cover sockets, files and the clock, not the process
environment), and `lib/args` already gives a `--port`/`--host` pair the usual
shell idioms (`httpserver --port "${PORT:-8080}"`) work with anyway.

## Serving https

    httpserver --tls-cert chain.pem --tls-key key.pem --port 8443

`--tls-cert` is a **PEM** certificate chain, leaf first (intermediates after
it; the root is optional); `--tls-key` is the PEM private key of that leaf,
**Ed25519 or ECDSA P-256** (PKCS#8, or SEC1 for P-256). Each file may also be
**DER**, told apart from PEM by content: the certificate file as one or more
certificates laid end to end, the key file as PKCS#8 or SEC1; the two files
need not be in the same form. The two go together: giving one
without the other is a usage error (exit 2). Without them nothing changes --
the listener speaks plain HTTP exactly as before. One port speaks one or the
other, never both. RSA keys, encrypted keys, ALPN beyond `http/1.1`,
client certificates (the server never asks for one, so an Ed25519 client
certificate is not something it can be tested with), session resumption and
0-RTT are not supported (`lib/tlsserver.m31` documents the full list; it serves TLS 1.3
with `TLS_CHACHA20_POLY1305_SHA256` and x25519 only).

The pair is loaded and checked **before the port is opened**: an unreadable
file, a chain that is not PEM, a key that is encrypted, of an unsupported
kind, or not the one the first certificate certifies makes the server print
one line naming the two files and the reason, and exit 1. That line never
contains a byte of either file; neither does anything else this server
prints (`tlsserver.ConfigError` is payload-free by contract, and the test
suite greps every server output for the key's body lines).

After the handshake a connection is served by the same code as a plain one:
the same handler, keep-alive, the `http.MAX_REQUESTS` cap per connection, the
same refusal (and the same 400/431 answers) for a malformed or oversized
request, and no read or write timeout on an established connection.
Both go through `http.serve_stream`, which takes any `io.Stream`
(`http.serve_conn` is its `net.Conn` wrapper), so a TLS connection is served
by the very loop the plain path uses; the tests compare the two paths'
answers.

A failed `accept` is handled the way `http.serve` handles it: if
`error.is_transient()` (out of descriptors, a client that gave up in the
backlog) the loop pauses 10 ms and accepts again; anything else means the
listener is no good and the server stops with a message.

### Handshakes cannot stall the server

The handshake is the one point where a peer makes this server wait before it
has said a word, so it is handled apart from everything else:

- The accept loop does nothing but hand each new connection to a bounded pool
  of **handshake workers** (`--tls-handshake-workers`, default 4) through a
  channel, so a slow handshake can never stop `accept`. A finished handshake
  moves to a green thread of its own, exactly like a plain connection, and
  the worker takes the next one.
- Each read of a handshake has a timeout (`--tls-handshake-timeout-ms`,
  default 5000, at least 1 -- never "wait forever"), and the whole handshake
  has `tlsserver.accept`'s default 30 s deadline. A client that connects
  and sends nothing, or stops halfway through, loses its socket when one
  fires; a garbage or truncated hello, a TLS 1.2-only client and a plain
  HTTP request on the https port are answered with an alert (or just closed)
  and forgotten. Nothing a handshake does can end the process or touch
  another connection.
- A bounded wait parks the waiting green thread only, never a carrier OS
  thread, so stalled handshakes cannot starve established connections
  whatever the pool size or carrier count (`nproc`, or `LANG_NUM_CARRIERS`):
  the tests run with two carriers, four silent connections and eight
  workers, and a real request still completes in a fraction of a second.
  (Earlier versions of the standard library did a blocking `poll(2)` on the
  carrier, which is why this server used to size the pool below the carrier
  count and warn when it was not.)
- The cost of the pool is that silent connections queue for the workers, so
  *k* of them delay a legitimate client by up to
  about *k* x timeout / workers (8 silent clients on 2 workers with a 0.7 s
  timeout delay a good client by under 3 s in the tests). Up to 256
  connections wait for a worker; past that the accept loop waits and the
  kernel's listen backlog takes over. The timeout bounds each *read* and
  the deadline the whole handshake (`lib/tlsserver.m31`, "Denial of service"),
  so a peer that drips a byte per timeout holds a worker for at most 30 s.
  Rate-limit in
  front of this server if hostile clients matter; this is a stdlib limit,
  not something `main.m31` can tighten with the primitives there are.

Each worker loads its own copy of the chain and key from the files: a
`tlsserver.Config` holds refcounted objects and refcounts are not atomic, so
one cannot be shared between green threads.

Other flags: `--tls-handshake-timeout-ms MS`, `--tls-handshake-workers N`.

## Serving files: `--root DIR`

    httpserver --root ./public --port 8080
    httpserver --root ./public --listing --cache 3600
    httpserver --root ./public --tls-cert chain.pem --tls-key key.pem

With `--root` the server answers `GET` and `HEAD` for files below DIR instead of
"Hello, World!". Plain http and https both work; the same code serves both.

| flag | meaning |
|---|---|
| `--root DIR` | the directory to serve (must exist) |
| `--index NAME` | file a directory answers with (default `index.html`) |
| `--listing` | list a directory that has no index file; off by default (403) |
| `--dotfiles` | serve and list names that begin with `.`; hidden by default |
| `--cache SECONDS` | `Cache-Control: public, max-age=N`; 0 (default) is `no-cache`, i.e. always revalidate |

The other flags (`--host`, `--port`, `--backlog`, `--tls-*`) are unchanged.
`--index`, `--listing`, `--dotfiles` and `--cache` without `--root` are a usage
error. Without `--root` nothing changes: every request still gets the fixed
reply.

What it does:

- **Content-Type** from the extension, case-insensitively (html, htm, css, js,
  mjs, json, txt, md, csv, xml, svg, png, jpg, gif, webp, avif, ico, pdf, wasm,
  woff/woff2, fonts, archives, audio, video, ...), `charset=utf-8` on text
  types, `application/octet-stream` for anything else. `X-Content-Type-Options:
  nosniff` on everything.
- **Directories**: `/dir` redirects (301) to `/dir/`, rebuilt from the decoded
  path so a request like `//host` can never become an open redirect; `/dir/`
  serves its index file, else the listing if `--listing`, else 403.
- **Listing** is HTML (names escaped, links quoted, a `default-src 'none'`
  CSP), or JSON with `Accept: application/json` (when `text/html` is not also
  accepted), `?json` or `?format=json`: `{"path", "entries": [{"name", "type",
  "size", "mtime"}], "truncated"}`, directories first, sorted, at most 10000
  entries. Symlinks and (without `--dotfiles`) dotfiles are not listed.
- **Validators and conditionals** (RFC 9110 order): strong `ETag` (mtime in
  nanoseconds and size) and `Last-Modified` on every file response;
  `If-Match` / `If-Unmodified-Since` (412), `If-None-Match` /
  `If-Modified-Since` (304, with the validators and `Cache-Control`).
- **One byte range**: `Accept-Ranges: bytes`, `206` with `Content-Range`, `416`
  with `Content-Range: bytes */SIZE`, `If-Range`. Several ranges, other units or a
  malformed `Range` get the whole file (RFC 9110 14.2 allows it). `HEAD`
  ignores `Range`.
- **Streaming**: a file is read and written in 64 KiB pieces (the first piece
  goes out with the head in one write), so memory is flat whatever the size,
  and keep-alive, pipelining and `Connection: close` work around it. A client
  that goes away mid-download costs nothing.
- Errors are `text/plain` with a one-line body that never repeats anything the
  client sent: 400 (bad path), 403, 404, 405 (`Allow: GET, HEAD, OPTIONS`),
  412, 414, 416, 503 (out of descriptors).

### What a request can reach

The path is split on `/` and each piece is percent-decoded **once**, then
checked:

- a piece that decodes to something with a NUL or other control character, a
  `/` (`%2f`) or a `\` is a 400;
- a piece that decodes to `..` (`..`, `%2e%2e`, `.%2e`, ...) is a 400, wherever
  it is. Real clients resolve `..` before sending, so one that arrives is an
  attack, not a typo;
- double encoding is not decoded twice: `%252e%252e` is a file named `%2e%2e`;
- a name that starts with `.` is a 404, byte-identical to a missing file's
  (no existence oracle), unless `--dotfiles`;
- **a symbolic link is never served and never followed**: every component below
  the root is checked with `lstat` and a link anywhere is a 403, whether it
  points outside the root or not. The standard library has no `realpath` or
  `readlink`, so "the link stays inside" cannot be verified, and refusing all
  of them is the only safe answer. (The root itself may be a link.)
- only regular files are opened (a FIFO or device is a 404, never opened).

One thing no path check can fix: between the `lstat` and the `open` someone who
can *write* inside the served tree could swap a directory for a link. Serve a
tree only the server's operator can write.

Also: the request target that is not valid UTF-8 (`GET /\xff`) crashed the
whole process in m31 0.3.2's `http.read_request` (a trap, not an error). Both
modes now filter the request line first and answer 400. See `fileserver.m31`;
delete the guard when the standard library is fixed.

Limits worth knowing: no `sendfile`/`mmap` from m31 (every byte is read and
written in user space), no seek (a range starting at byte N reads and discards
N bytes first: constant memory, linear time), no `Content-Encoding`
(no compression), no timeouts on an idle connection (as before), and https
throughput is that of the pure-m31 TLS stack (a few MB/s per stream).
`bench/STATIC_BENCHMARK.md` has numbers against Python's `http.server`.

## Why this is not just `http.serve(ln, hello)`

`http.serve`'s own doc comment ("One connection at a time, and why") says
plainly that it serves one connection to completion before accepting the
next -- not a bug, a consequence of `spawn` moving its arguments: `serve`'s
`Handler` parameter is *borrowed*, and a borrowed value may not be moved into
a spawned green thread, so `serve` cannot hand each connection its own
thread without first giving every handler either module-constant status or a
worker-pool shape neither of which `serve` picks for its caller.

A **plain top-level function** sidesteps this. Per
`docs/closures-decision.md` §3.4 ("No captures"), a function's name used
where a one-method interface is expected is one static, immortal instance
per (function, interface) pair -- free across threads, nothing to move or
clone, by construction. `hello` here is exactly that, so this program writes
its own accept loop (the same shape as
`runtime/net_concurrency_demo/main.m31`): `ln.accept()`, `spawn
handle_conn(c)`, repeat, with `handle_conn` calling the public
`http.serve_conn(c, hello)` on its own green thread. This is precisely the
pattern `http.serve`'s doc comment describes as "a program a caller can
write today on top of `serve_conn`."

## A note on read/write timeouts

This server does **not** call `set_read_timeout`/`set_write_timeout` on its
established connections, unlike `http.serve`'s own default (`deadline()`, 30s
both ways). A silent, never-sending peer therefore holds a green thread open
until it disconnects -- cheap (one small stack), but not free.

That used to be forced: a *bounded* wait on a non-blocking socket was a real
blocking `poll(2)` on the carrier OS thread (see `BENCHMARK.md`'s "A second
finding"), and once idle keep-alive connections with a timeout outnumbered
the carriers, none was left to run anything else. The standard library no
longer does that -- a socket's timeout now parks only the green thread -- so
the stall is gone, whether or not a timeout is set, and a deployment that
wants idle connections reaped can add one. `BENCHMARK.md` and `SCALING.md`
record the measurements taken before that change.

## Testing

`bash scripts/test.sh` builds the server, starts it on a scratch
port, and checks, against the real built binary over a real socket (no
mocking):

1. A single request: status 200, the exact body, a correct `Content-Length`.
2. A second request on the **same** kept-alive connection gets the same
   answer (`serve_conn`'s keep-alive loop is exercised, not just one
   request-then-close).
3. Several different paths/methods all get the same reply (this handler
   ignores the request entirely, on purpose).
4. **Concurrent load**: `N` simultaneous persistent connections, each
   issuing several sequential requests, all of which must succeed -- the
   actual property this whole app exists to demonstrate (every accepted
   connection runs on its own green thread; concurrent real socket I/O does
   not serialize on one carrier).
5. `--help`, a bad flag, and a bad `--port` are refused the way `lib/args`
   refuses them.
6. **https** (needs `openssl` and `python3`; the curl checks need `curl`).
   A throwaway CA, an Ed25519 leaf and a P-256 leaf are made with `openssl`;
   the clients are `curl --cacert`, the standard library's own `https`
   client with a custom `tls.Trust.CaFile` (`scripts/https_client.m31`; it
   verifies both the P-256 and the Ed25519 certificate), and Python's `ssl`.
   Servers are also started from DER files (a P-256 chain with a PKCS#8 key,
   a single certificate with a SEC1 key, an Ed25519 chain with a PKCS#8 key,
   and PEM/DER mixes), each checked with all three clients. Covered: a valid request, keep-alive (curl reuses one
   connection; five requests and then `Connection: close` over Python's),
   the CA being required, the limits (a 9000-byte header line, a malformed
   request, 1000 requests per connection) giving the same answers as plain
   HTTP, random bytes / zeros / plain HTTP / a truncated hello / an alert
   record / a huge record length / a TLS 1.2-only client on the https port
   with the server still serving afterwards, a client that connects and
   sends nothing and one that stops mid-record (both closed within the
   timeout, a good client unaffected, then eight silent clients on two
   workers), **silent clients on two carriers** (`LANG_NUM_CARRIERS=2`, four
   connections that open and send nothing, over plain HTTP and over https:
   real requests still complete in under a second), and startup refusal of
   a key that is not the certificate's (PEM or DER), an RSA key, an encrypted
   key, a garbage or truncated key, a certificate file that is not one, a
   missing certificate,
   one flag without the other, and a zero timeout or worker count -- with
   every refusal and every server output checked for key material.

7. **Static files** (`bash scripts/test_static.sh`, run by `test.sh`; needs
   `python3` and `curl`, https also `openssl`; groups can be run alone:
   `cli oracle fuzz stream policy https`). Disposable tree with a sibling
   directory, outside secrets, dotfiles, ten kinds of symlink, a FIFO and
   random files of 3, 12 and 64 MiB (`STATIC_BIG_MIB`). Oracles: Python's
   `http.server` (status, body, `Content-Length`, redirects, HEAD, 304),
   `mimetypes` (types), `curl` (conditional requests, `--range`, `-C -`
   resume, `-L`, `--path-as-is`). A traversal corpus (named attacks with
   required statuses, ~3000 generated escape forms, 2500 seeded random
   targets, malformed request lines and framings, invalid UTF-8) asserting
   that no secret is ever in a body, every 200 body is a file meant to be
   served, no 5xx, no unsafe `Location`, and the server is alive after.
   Large-file streaming with sha256 and a server-RSS bound, ranges into the
   middle of a 64 MiB file, keep-alive across files/404/301/405/HEAD/206,
   pipelining, clients that abandon or stall mid-download, 24 concurrent
   clients, HEAD parity with GET, the listing and dotfile policy, `--index`,
   `--cache`, and the same streaming and fuzz checks over https.

`BENCHMARK.md` is the throughput/latency comparison against an equivalent Go
`net/http` server, with methodology, raw numbers and honest caveats; it is
exploratory measurement, not part of this test suite, and not part of the
ordinary corpus (`httpserver` is a long-running server, not a short
pass/fail program, so `gates.sh` does not build or run it). `SCALING.md` is
the complementary question -- not "how fast at a few fixed concurrency
levels" but "how far does concurrency go before something degrades or
breaks" -- ramping the same two servers from 100 to 20,000 concurrent
connections and measuring where (and why) each one's throughput and
latency diverge from the other.
