# `httpserver` -- a "Hello, World!" HTTP/1.1 server

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
**Ed25519 or ECDSA P-256** (PKCS#8 or SEC1). The two go together: giving one
without the other is a usage error (exit 2). Without them nothing changes --
the listener speaks plain HTTP exactly as before. One port speaks one or the
other, never both. DER files, RSA keys, encrypted keys, ALPN beyond
`http/1.1`, client certificates, session resumption and 0-RTT are not
supported (`lib/tlsserver.m31` documents the full list; it serves TLS 1.3
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
`http.serve_conn` takes a `net.Conn`, not an `io.Stream`, so `main.m31` carries
that loop (`serve_stream`) as a small copy built from the same public pieces
(`read_request`, `write_response`, `should_keep_alive`); the tests compare its
answers with the plain path's.

### Handshakes cannot stall the server

The handshake is the one point where a peer makes this server wait before it
has said a word, so it is handled apart from everything else:

- The accept loop does nothing but hand each new connection to a bounded pool
  of **handshake workers** (`--tls-handshake-workers`, default 4) through a
  channel, so a slow handshake can never stop `accept`. A finished handshake
  moves to a green thread of its own, exactly like a plain connection, and
  the worker takes the next one.
- Each read of a handshake has a timeout (`--tls-handshake-timeout-ms`,
  default 5000, at least 1 -- never "wait forever"). A client that connects
  and sends nothing, or stops halfway through, loses its socket when it
  fires; a garbage or truncated hello, a TLS 1.2-only client and a plain
  HTTP request on the https port are answered with an alert (or just closed)
  and forgotten. Nothing a handshake does can end the process or touch
  another connection.
- A bounded wait is a `poll(2)` that occupies a carrier OS thread (see
  "A note on read/write timeouts"), so the pool size is the **most carriers
  stalled handshakes can occupy**. Keep `--tls-handshake-workers` below the
  carrier count (`nproc`, or `LANG_NUM_CARRIERS` if set -- the server warns
  when it can see that the pool is not below it) and established connections
  keep being served however many handshakes are stalled.
- The cost of that bound is the second thing to know: silent connections
  queue for the workers, so *k* of them delay a legitimate client by up to
  about *k* x timeout / workers (8 silent clients on 2 workers with a 0.7 s
  timeout delay a good client by under 3 s in the tests). Up to 256
  connections wait for a worker; past that the accept loop waits and the
  kernel's listen backlog takes over. The timeout bounds each *read*, not the
  whole handshake (`lib/tlsserver.m31`, "Denial of service"), so a peer that
  drips a byte per timeout can hold a worker much longer. Rate-limit in
  front of this server if hostile clients matter; this is a stdlib limit,
  not something `main.m31` can tighten with the primitives there are.

Each worker loads its own copy of the chain and key from the files: a
`tlsserver.Config` holds refcounted objects and refcounts are not atomic, so
one cannot be shared between green threads.

Other flags: `--tls-handshake-timeout-ms MS`, `--tls-handshake-workers N`.

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
connections, unlike `http.serve`'s own default (`deadline()`, 30s both
ways). That is a deliberate choice, not an oversight -- see
`BENCHMARK.md`'s "A second finding" for the full account: a *bounded*
wait on a non-blocking socket is implemented in `lib/net.m31` with a real
blocking `poll(2)` syscall on the calling green thread's own carrier OS
thread, because a non-blocking socket has no kernel-level receive timeout to
fall back on any more. That syscall does not free its carrier the way the
reactor-parked, unbounded wait does, so once concurrently open idle
keep-alive connections outnumber the carrier count (`nproc`, by default),
every carrier can end up parked inside somebody else's `poll()`, with none
left to service the rest -- a severe, reproducible stall, not a crash or a
wrong answer. Leaving the timeout at its default (wait forever,
cooperatively, via the reactor) is what makes this server actually scale
with concurrency, at the cost of a silent, never-sending peer holding a
green thread open indefinitely -- cheap (one small stack), but not free, and
a production server would want a real answer to this before shipping, which
is exactly what `BENCHMARK.md` recommends as follow-up work.

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
   cannot verify an Ed25519 certificate, so it talks to the P-256 server),
   and Python's `ssl`. Covered: a valid request, keep-alive (curl reuses one
   connection; five requests and then `Connection: close` over Python's),
   the CA being required, the limits (a 9000-byte header line, a malformed
   request, 1000 requests per connection) giving the same answers as plain
   HTTP, random bytes / zeros / plain HTTP / a truncated hello / an alert
   record / a huge record length / a TLS 1.2-only client on the https port
   with the server still serving afterwards, a client that connects and
   sends nothing and one that stops mid-record (both closed within the
   timeout, a good client unaffected, then eight silent clients on two
   workers), and startup refusal of a key that is not the certificate's, an
   RSA key, an encrypted key, a garbage key, a DER or missing certificate,
   one flag without the other, and a zero timeout or worker count -- with
   every refusal and every server output checked for key material.

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
