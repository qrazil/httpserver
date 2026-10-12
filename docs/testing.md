# Testing httpserver

`bash tests/test.sh` builds the server, starts it on a scratch
port, and checks, against the real built binary over a real socket (no
mocking):

1. A single request: status 200, the exact body, a correct `Content-Length`.
2. A second request on the **same** kept-alive connection gets the same
   answer (`serve_connection`'s keep-alive loop is exercised, not just one
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
   client with a custom `tls.Trust.CaFile` (`tests/https_client.m31`; it
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

7. **Static files** (`bash tests/test_static.sh`, run by `tests/test.sh`; needs
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

`bench/BENCHMARK.md` is the throughput/latency comparison against an equivalent Go
`net/http` server, with methodology, raw numbers and honest caveats; it is
exploratory measurement, not part of this test suite, and not part of the
ordinary corpus (`httpserver` is a long-running server, not a short
pass/fail program, so `gates.sh` does not build or run it). `bench/SCALING.md` is
the complementary question -- not "how fast at a few fixed concurrency
levels" but "how far does concurrency go before something degrades or
breaks" -- ramping the same two servers from 100 to 20,000 concurrent
connections and measuring where (and why) each one's throughput and
latency diverge from the other.
