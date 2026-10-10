# Static files: `httpserver --root` vs `python3 -m http.server`

`bash bench/static_bench.sh` (needs `hey`; nginx and caddy are included
automatically when installed -- neither was installed on the machine below, so
there are no numbers for them). Loopback only; 12 logical CPUs, x86-64 Linux,
load average 8.35 / 6.94 / 4.64 at the start (a shared host with other builds
running -- read the ratios, not the absolutes). `hey -z 8s`, keep-alive on,
one run per cell. Python 3.12's `http.server` (a `ThreadingHTTPServer`).

| file | server | c=1 req/s | c=16 req/s | c=64 req/s |
|---|---|---:|---:|---:|
| 1 KiB | httpserver | 3354 | 13771 | 20379 |
| 1 KiB | python http.server | 981 | 1054 | errors (non-200 / refused) |
| 100 KiB | httpserver | 2217 | 11150 | 14838 |
| 100 KiB | python http.server | 1029 | 468 | errors |

256 MiB, one `curl` download, median of 3:

| server | time | MB/s | server RSS afterwards |
|---|---:|---:|---:|
| httpserver | 0.20 s | 1359 | 6 MB |
| python http.server | 0.17 s | 1569 | 18 MB |

What this says, and does not:

- On small files `httpserver` is several times faster than Python's
  `http.server`, which speaks HTTP/1.0 (a new connection per request) and has a
  small listen backlog, so it drops connections at 64 clients.
- On one big file both are limited by the loopback and the page cache; Python
  is about 15 % faster per stream (it copies in larger blocks), `httpserver`
  moves the file in 64 KiB pieces and its RSS stays at 6 MB however big the
  file is (the streaming test in `scripts/test_static.sh` checks that).
- Over https the bottleneck is the pure-m31 TLS stack, not the file server:
  about 3 MB/s for one stream in the test suite. Not benchmarked against
  anything.
- `sendfile`/`mmap` are not reachable from m31, so every byte goes through a
  user-space read and write.
