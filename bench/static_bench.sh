#!/usr/bin/env bash
# A quick comparison of `httpserver --root` with `python3 -m http.server` (and
# nginx / caddy when installed) serving static files from loopback.
#
#   bash bench/static_bench.sh                 needs ./httpserver and `hey`
#   SECONDS_PER_RUN=10 CONC="1 16 64" bash bench/static_bench.sh
#
# Small file: a 1 KiB and a 100 KiB file under keep-alive load (hey). Large
# file: one 256 MiB download, wall-clock seconds and MB/s, median of 3 (curl).
# Not a rigorous benchmark: one machine, shared with whatever else is running,
# everything on loopback. Read the ratios, not the absolutes.
set -uo pipefail
cd "$(dirname "$0")/.."
BIN=${HTTPSERVER_BIN:-./httpserver}
DUR=${SECONDS_PER_RUN:-8}
CONC=${CONC:-"1 16 64"}
BIGMIB=${BIGMIB:-256}
WORK=$(mktemp -d)
pids=""
cleanup() { for p in $pids; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; rm -rf "$WORK"; }
trap cleanup EXIT
command -v hey >/dev/null || { echo "need hey (go install github.com/rakyll/hey@latest)"; exit 1; }

R=$WORK/root
mkdir -p "$R"
python3 - "$R" "$BIGMIB" <<'PY'
import os, sys
r, mib = sys.argv[1], int(sys.argv[2])
open(r + "/small.txt", "wb").write(os.urandom(512).hex().encode())          # 1 KiB
open(r + "/medium.bin", "wb").write(os.urandom(100 * 1024))                  # 100 KiB
with open(r + "/big.bin", "wb") as f:
    for _ in range(mib):
        f.write(os.urandom(1 << 20))
PY

wait_port() { for _ in $(seq 1 100); do (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && { exec 3>&-; return 0; }; sleep 0.05; done; return 1; }

servers="httpserver python"
command -v nginx >/dev/null && servers="$servers nginx"
command -v caddy >/dev/null && servers="$servers caddy"

start_server() {
    local attempt
    for attempt in 1 2 3 4 5; do
        start_once "$1" && return 0
        kill "$SP" 2>/dev/null; wait "$SP" 2>/dev/null
    done
    return 1
}

start_once() {
    P=$((20000 + (RANDOM % 20000)))   # not in a subshell: RANDOM must advance
    case $1 in
        httpserver) "$BIN" --port "$P" --host 127.0.0.1 --root "$R" >/dev/null 2>&1 & ;;
        python) (cd "$R" && exec python3 -m http.server "$P" --bind 127.0.0.1 --directory "$R") >/dev/null 2>&1 & ;;
        nginx)
            printf 'daemon off; worker_processes auto; pid %s/nginx.pid; error_log /dev/null;\nevents{}\nhttp{access_log off; sendfile on; server{listen 127.0.0.1:%s; root %s;}}\n' "$WORK" "$P" "$R" >"$WORK/nginx.conf"
            nginx -c "$WORK/nginx.conf" -p "$WORK" >/dev/null 2>&1 & ;;
        caddy) caddy file-server --listen "127.0.0.1:$P" --root "$R" >/dev/null 2>&1 & ;;
    esac
    SP=$!
    pids="$pids $SP"
    wait_port "$P"
}

echo "machine: $(nproc) CPUs, load $(uptime | sed 's/.*load average[s]*: //')"
echo
for what in small.txt medium.bin; do
    echo "== $what (hey, keep-alive, ${DUR}s per run)"
    printf '%-12s' server; for c in $CONC; do printf '%16s' "c=$c req/s"; done; echo
    for s in $servers; do
        start_server "$s" || { echo "$s: did not start"; continue; }
        printf '%-12s' "$s"
        for c in $CONC; do
            out=$(hey -z "${DUR}s" -c "$c" "http://127.0.0.1:$P/$what" 2>&1)
            rps=$(printf '%s' "$out" | awk '/Requests\/sec/{printf "%.0f", $2}')
            if printf '%s' "$out" | grep -q 'Error distribution'; then rps="ERR"; fi
            if printf '%s' "$out" | grep -E '^\s+\[[0-9]+\]' | grep -vq '\[200\]'; then rps="non-200"; fi
            printf '%16s' "$rps"
        done
        echo
        kill "$SP" 2>/dev/null; wait "$SP" 2>/dev/null
    done
    echo
done

echo "== big.bin (${BIGMIB} MiB, curl, median of 3)"
for s in $servers; do
    start_server "$s" || { echo "$s: did not start"; continue; }
    times=""
    for _ in 1 2 3; do
        t=$(curl -s -o /dev/null -w '%{time_total}' "http://127.0.0.1:$P/big.bin")
        times="$times $t"
    done
    med=$(printf '%s\n' $times | sort -n | sed -n 2p)
    printf '%-12s %6.2f s  %6.0f MB/s\n' "$s" "$med" "$(awk -v t="$med" -v m="$BIGMIB" 'BEGIN{print m*1.048576/t}')"
    rss=$(ps -o rss= -p "$SP" 2>/dev/null | tr -d ' ')
    [ -n "$rss" ] && printf '%-12s server RSS after: %s MB\n' "" "$((rss / 1024))"
    kill "$SP" 2>/dev/null; wait "$SP" 2>/dev/null
done
