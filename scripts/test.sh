#!/usr/bin/env bash
# httpserver's own tests: builds the real binary, runs it on a scratch
# port, and talks to it over a real socket -- curl for the simple checks, a
# small Python client (threads, real `socket`s, nothing mocked) for the
# concurrent-load check, which is the one this whole app exists to pass.
#
#   M31_ROOT=/path/to/m31 bash test.sh
#
# See build.sh's own header for what M31_ROOT (and LANGC, if the compiler
# isn't at $M31_ROOT's own default) need to point at.
set -uo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
pass=0
fail=0
server_pid=""

note() { printf '\033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '\033[31mFAIL\033[0m %s\n' "$1"; shift; printf '%s\n' "$@" | sed 's/^/     /'; fail=$((fail + 1)); }

cleanup() {
    [ -n "$server_pid" ] && kill "$server_pid" >/dev/null 2>&1
    [ -n "$server_pid" ] && wait "$server_pid" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

if ! bash scripts/build.sh >"$WORK/build.log" 2>&1; then
    bad "build" "$(cat "$WORK/build.log")"
    exit 1
fi
note "build: ./httpserver"

BIN=./httpserver
PORT=$((20000 + (RANDOM % 20000)))
BASE="http://127.0.0.1:$PORT"

"$BIN" --port "$PORT" --host 127.0.0.1 >"$WORK/server.log" 2>&1 &
server_pid=$!

up=0
tries=0
while [ "$tries" -lt 100 ]; do
    if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
        exec 3>&-
        up=1
        break
    fi
    sleep 0.05
    tries=$((tries + 1))
done

if [ "$up" != 1 ]; then
    bad "server start" "$(cat "$WORK/server.log")"
    exit 1
fi
note "server: listening on 127.0.0.1:$PORT (pid $server_pid)"

# --- 1. one request: status, body, Content-Length ---------------------------

resp=$(curl -s -D "$WORK/h1" -o "$WORK/b1" -w '%{http_code}' "$BASE/")
body=$(cat "$WORK/b1")
clen=$(tr -d '\r' <"$WORK/h1" | grep -i '^content-length:' | awk '{print $2}')
if [ "$resp" = "200" ] && [ "$body" = $'Hello, World!' ] && [ "$clen" = "14" ]; then
    note "one request: 200, exact body, Content-Length: 14"
else
    bad "one request" "status=$resp body=[$body] content-length=[$clen]"
fi

# --- 2. a second (and third) request on the SAME kept-alive connection ------
# No `-o` here on purpose: curl reuses one connection across multiple URLs
# given on one command line, and with no output file to disagree about, all
# three bodies land on stdout, concatenated, in order.

two=$(curl -s "$BASE/" "$BASE/" "$BASE/")
want_two=$'Hello, World!\nHello, World!\nHello, World!'
if [ "$two" = "$want_two" ]; then
    note "keep-alive: three sequential requests on one connection all answered"
else
    bad "keep-alive" "got [$two]"
fi

# --- 3. different paths and methods get the same reply (ignores the request) -

ok3=1
for args in "$BASE/" "$BASE/anything/at/all" "$BASE/?x=1" "-X POST $BASE/post" "--head $BASE/head"; do
    # --head (not -X HEAD): curl only knows to stop expecting a body on a
    # HEAD *response* when it knows the *request* was HEAD through this
    # flag -- `-X HEAD` just swaps the method word and otherwise reads the
    # reply like a GET, so it hangs waiting for Content-Length bytes a
    # correct HEAD response (ours) never sends on a kept-alive connection.
    # Confirmed against Python's own http.server: the same `-X HEAD` hangs
    # there too (or errors, over HTTP/1.0) -- a curl footgun, not a server
    # bug; curl's own warning says exactly this ("use -I/--head instead").
    out=$(eval curl -s -o /dev/null -w "'%{http_code}'" --max-time 5 "$args")
    if [ "$out" != "200" ]; then
        ok3=0
        bad "path/method $args" "status=$out"
    fi
done
[ "$ok3" = 1 ] && note "every path and method gets 200 (the handler ignores the request)"

# --- 4. concurrent load: N persistent connections x M sequential requests ---
# each -- the actual property this app exists to demonstrate: every accepted
# connection is its own green thread, so real concurrent socket I/O does not
# serialize on one carrier. Run twice (different N) to make the claim a
# little stronger than one lucky pass.

concurrent_check() {
    local n=$1 m=$2
    python3 - "$PORT" "$n" "$m" <<'PY'
import socket
import sys
import threading

port = int(sys.argv[1])
n = int(sys.argv[2])
m = int(sys.argv[3])
ok = [True] * n
errs = [""] * n


def worker(i):
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=10)
        s.settimeout(10)
        for _ in range(m):
            s.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
            data = b""
            while b"\r\n\r\n" not in data:
                chunk = s.recv(4096)
                if not chunk:
                    raise RuntimeError("connection closed early")
                data += chunk
            head, _, rest = data.partition(b"\r\n\r\n")
            if b" 200 " not in head.split(b"\r\n", 1)[0]:
                raise RuntimeError("not 200: " + head.split(b"\r\n", 1)[0].decode())
            need = 14 - len(rest)
            while need > 0:
                chunk = s.recv(need)
                if not chunk:
                    raise RuntimeError("short body")
                need -= len(chunk)
        s.close()
    except Exception as e:
        ok[i] = False
        errs[i] = repr(e)


threads = [threading.Thread(target=worker, args=(i,)) for i in range(n)]
for t in threads:
    t.start()
for t in threads:
    t.join(15)
failed = [i for i in range(n) if not ok[i]]
if failed:
    print(f"FAIL {len(failed)}/{n} connections failed: {errs[failed[0]]}")
    sys.exit(1)
print(f"OK {n} connections x {m} requests each, all succeeded")
PY
}

if out=$(concurrent_check 40 10 2>&1); then
    note "concurrent load: $out"
else
    bad "concurrent load (40x10)" "$out"
fi

if out=$(concurrent_check 80 5 2>&1); then
    note "concurrent load: $out"
else
    bad "concurrent load (80x5)" "$out"
fi

# --- 5. the command line: --help, a bad flag, a bad port --------------------

help_out=$("$BIN" --help)
if printf '%s' "$help_out" | grep -q "httpserver"; then
    note "--help prints usage"
else
    bad "--help" "$help_out"
fi

if "$BIN" --nonsense >"$WORK/badflag.out" 2>&1; then
    bad "bad flag accepted" "$(cat "$WORK/badflag.out")"
else
    note "a bad flag is refused (exit nonzero)"
fi

if "$BIN" --port 99999 >"$WORK/badport.out" 2>&1; then
    bad "bad --port accepted" "$(cat "$WORK/badport.out")"
else
    note "a --port outside 0..65535 is refused with a message, not a trap"
fi

# --- 6. https: --tls-cert / --tls-key ---------------------------------------
# A throwaway CA and localhost leaves made with openssl; clients are curl
# (--cacert), the standard library's own `https` client with
# `tls.Trust.CaFile` (scripts/https_client.m31), and Python's ssl. The https
# servers listen on `localhost`, not 127.0.0.1: the m31 client resolves a
# name to the first address the resolver gives it and cannot match an IP
# literal against a certificate, and server and client resolve `localhost`
# the same way on any one machine.

have_https=1
for tool in openssl python3; do
    command -v "$tool" >/dev/null 2>&1 || have_https=0
done

HPIDS=()
stop_https() {
    for pid in ${HPIDS[@]+"${HPIDS[@]}"}; do
        kill "$pid" >/dev/null 2>&1
        wait "$pid" 2>/dev/null
    done
    HPIDS=()
}
trap 'stop_https; cleanup' EXIT

# start_https NAME CHAIN KEY [extra flags...] -> HPID, HPORT; log in $WORK/NAME.log
start_https() {
    local name=$1 chain=$2 key=$3
    shift 3
    HPORT=$((20000 + (RANDOM % 20000)))
    "$BIN" --port "$HPORT" --host localhost --tls-cert "$chain" --tls-key "$key" "$@" \
        >"$WORK/$name.log" 2>&1 &
    HPID=$!
    HPIDS+=("$HPID")
    local tries=0
    while [ "$tries" -lt 100 ]; do
        # Not the log: stdout is block-buffered into a file.
        if (exec 3<>"/dev/tcp/localhost/$HPORT") 2>/dev/null; then
            exec 3>&-
            return 0
        fi
        kill -0 "$HPID" 2>/dev/null || return 1
        sleep 0.05
        tries=$((tries + 1))
    done
    return 1
}

# no_key_material LOGFILE...: no line of any key file's body appears in the logs.
no_key_material() {
    local keyfile body
    for keyfile in "$FX"/*.key "$FX"/*.der; do
        [ -f "$keyfile" ] || continue
        case "$keyfile" in *.der) continue ;; esac
        while IFS= read -r body; do
            case "$body" in -----*|"") continue ;; esac
            [ "${#body}" -ge 16 ] || continue
            if grep -qF -- "$body" "$@" 2>/dev/null; then
                return 1
            fi
        done <"$keyfile"
    done
    return 0
}

if [ "$have_https" != 1 ]; then
    echo "skip https tests: need openssl and python3"
else
    FX=$WORK/fx
    mkdir -p "$FX"
    (
        cd "$FX" || exit 1
        openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out ca.key
        openssl req -x509 -new -key ca.key -sha256 -days 30 -subj /CN=httpserver-test-ca \
            -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign -out ca.pem
        # other-ca: a CA the servers' certificates were NOT issued by.
        openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out other-ca.key
        openssl req -x509 -new -key other-ca.key -sha256 -days 30 -subj /CN=httpserver-other-ca \
            -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign -out other-ca.pem
        leaf() { # leaf STEM genpkey-args...
            local stem=$1
            shift
            openssl genpkey "$@" -out "$stem.key"
            openssl req -new -key "$stem.key" -subj /CN=localhost -out "$stem.csr"
            printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=serverAuth\n' >"$stem.ext"
            openssl x509 -req -in "$stem.csr" -CA ca.pem -CAkey ca.key -CAcreateserial -days 30 \
                -extfile "$stem.ext" -out "$stem.pem"
        }
        leaf p256 -algorithm EC -pkeyopt ec_paramgen_curve:P-256
        leaf ed25519 -algorithm ed25519
        # A second P-256 key: not the one p256.pem certifies.
        openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out stranger.key
        cat p256.pem ca.pem >p256.chain
        cat ed25519.pem ca.pem >ed25519.chain
        # Keys the server cannot use.
        openssl genrsa -out rsa.key 2048
        openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 \
            | openssl pkcs8 -topk8 -v2 aes256 -passout pass:throwaway -out encrypted.key
        printf 'this is not a key\n' >garbage.key
        # The same material in DER: certificates (single, and a chain laid end
        # to end), and keys as PKCS#8 and as SEC1 EC.
        openssl x509 -in p256.pem -outform der -out p256.der
        openssl x509 -in ed25519.pem -outform der -out ed25519.der
        openssl x509 -in ca.pem -outform der -out ca.der
        cat p256.der ca.der >p256.chain.der
        cat ed25519.der ca.der >ed25519.chain.der
        openssl pkey -in p256.key -outform der -out p256.pk8.der
        openssl ec -in p256.key -outform der -out p256.sec1.der
        openssl pkey -in ed25519.key -outform der -out ed25519.pk8.der
        openssl pkey -in stranger.key -outform der -out stranger.pk8.der
        # Not a key and not a certificate, in DER's clothing.
        head -c 48 p256.pk8.der >truncated.pk8.der
    ) >"$WORK/fixtures.log" 2>&1 || { bad "https fixtures" "$(tail -5 "$WORK/fixtures.log")"; have_https=0; }
fi

if [ "$have_https" = 1 ]; then
    cat >"$WORK/https_checks.py" <<'PY'
import os
import socket
import ssl
import sys
import time

mode, port = sys.argv[1], int(sys.argv[2])
use_tls = sys.argv[3] == "tls"
ca = sys.argv[4] if len(sys.argv) > 4 else None
HOST = "localhost" if use_tls else "127.0.0.1"


def connect():
    sock = socket.create_connection((HOST, port), timeout=15)
    sock.settimeout(15)
    if not use_tls:
        return sock
    ctx = ssl.create_default_context(cafile=ca)
    return ctx.wrap_socket(sock, server_hostname="localhost")


class Peer:
    def __init__(self, sock):
        self.sock = sock
        self.buf = b""

    def response(self, request):
        """Send `request`; return (status line, headers lowercased, body) or None on EOF."""
        self.sock.sendall(request)
        while b"\r\n\r\n" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                return None
            self.buf += chunk
        head, _, rest = self.buf.partition(b"\r\n\r\n")
        lines = head.decode().split("\r\n")
        headers = {}
        for line in lines[1:]:
            name, _, value = line.partition(":")
            headers[name.strip().lower()] = value.strip()
        need = int(headers.get("content-length", "0"))
        while len(rest) < need:
            chunk = self.sock.recv(65536)
            if not chunk:
                return None
            rest += chunk
        self.buf = rest[need:]
        return lines[0], headers, rest[:need]

    def at_eof(self):
        try:
            return self.sock.recv(1) == b""
        except (ssl.SSLError, ConnectionError, socket.timeout):
            return True


GET = b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"


def check(cond, what):
    if not cond:
        print("FAIL " + what)
        sys.exit(1)


if mode == "keepalive":
    peer = Peer(connect())
    for number in range(5):
        got = peer.response(GET)
        check(got is not None and got[0] == "HTTP/1.1 200 OK" and got[2] == b"Hello, World!\n",
              "request %d: %r" % (number, got))
        check("connection" not in got[1], "request %d: unexpected Connection header" % number)
    got = peer.response(b"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
    check(got is not None and got[1].get("connection") == "close", "Connection: close not honoured: %r" % (got,))
    check(peer.at_eof(), "connection not closed after Connection: close")
    print("OK 5 kept-alive requests, then close")

elif mode == "limits":
    # The same limits over TLS as over plain TCP: print what happened, the
    # caller compares the two outputs.
    peer = Peer(connect())
    big = b"GET / HTTP/1.1\r\nHost: localhost\r\nX-Big: " + b"a" * 9000 + b"\r\n\r\n"
    got = peer.response(big)
    print("long header line:", got[0] if got else None, "closed" if peer.at_eof() else "open")
    peer = Peer(connect())
    got = peer.response(b"BOGUS\r\n\r\n")
    print("malformed request:", got[0] if got else None, got[1].get("connection") if got else None)
    peer = Peer(connect())
    count = 0
    last_close = None
    while True:
        got = peer.response(GET)
        if got is None:
            break
        count += 1
        last_close = got[1].get("connection")
        if last_close == "close":
            break
    print("requests on one connection:", count, "last Connection:", last_close, "closed" if peer.at_eof() else "open")

elif mode == "garbage":
    cases = {
        "random bytes": os.urandom(3000),
        "plain http": GET,
        "zeros": b"\0" * 200,
        "huge record length": b"\x16\x03\x03\xff\xff" + b"A" * 60000,
        "truncated hello then close": b"\x16\x03\x01\x00\xff\x01\x00\x00",
        "alert record": b"\x15\x03\x03\x00\x02\x02\x28",
    }
    for name, data in cases.items():
        sock = socket.create_connection((HOST, port), timeout=15)
        try:
            sock.sendall(data)
        except OSError:
            pass
        try:
            sock.shutdown(socket.SHUT_WR)
        except OSError:
            pass
        # Whatever the server says (an alert, or nothing), it must end it.
        deadline = time.time() + 15
        closed = False
        while time.time() < deadline:
            try:
                if sock.recv(4096) == b"":
                    closed = True
                    break
            except OSError:
                closed = True
                break
        check(closed, "server did not close after " + name)
        sock.close()
    # A TLS 1.2-only client is refused with protocol_version, not served.
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.load_verify_locations(ca)
    ctx.maximum_version = ssl.TLSVersion.TLSv1_2
    try:
        ctx.wrap_socket(socket.create_connection((HOST, port), timeout=15), server_hostname="localhost")
        check(False, "a TLS 1.2-only client was served")
    except ssl.SSLError as error:
        check("PROTOCOL_VERSION" in str(error).upper().replace(" ", "_"), "tls1.2: " + str(error))
    # And a good client afterwards is served.
    peer = Peer(connect())
    got = peer.response(GET)
    check(got is not None and got[0] == "HTTP/1.1 200 OK", "good request after garbage: %r" % (got,))
    print("OK %d garbage handshakes and a TLS 1.2 client refused, then a good request served" % len(cases))

elif mode == "silent":
    # sys.argv[5]: how many silent connections; sys.argv[6]: ceiling in seconds
    # for them all to be closed by the server.
    count, ceiling = int(sys.argv[5]), float(sys.argv[6])
    started = time.time()
    silent = [socket.create_connection((HOST, port), timeout=30) for _ in range(count)]
    # A half-sent record header stalls mid-handshake rather than before it.
    half = socket.create_connection((HOST, port), timeout=30)
    half.sendall(b"\x16\x03\x01")
    time.sleep(0.2)
    began = time.time()
    peer = Peer(connect())
    got = peer.response(GET)
    check(got is not None and got[0] == "HTTP/1.1 200 OK", "good client while silent ones wait: %r" % (got,))
    took = time.time() - began
    check(took < ceiling, "good client took %.1fs behind %d silent connections" % (took, count))
    closed_at = {}
    for number, sock in enumerate(silent + [half]):
        sock.settimeout(ceiling)
        try:
            data = sock.recv(4096)
        except socket.timeout:
            check(False, "silent connection %d still open after %.0fs" % (number, ceiling))
        except OSError:
            data = b""
        closed_at[number] = time.time() - started
    print("OK %d silent + 1 stalled connections all closed by the server within %.1fs; a good client waited %.1fs"
          % (count, max(closed_at.values()), took))

elif mode == "blocked":
    # sys.argv[5]: how many silent connections (a socket opened and then
    # nothing, no TLS hello for https); sys.argv[6]: ceiling in seconds for a
    # real request made while they are all still open.
    count, ceiling = int(sys.argv[5]), float(sys.argv[6])
    silent = [socket.create_connection((HOST, port), timeout=30) for _ in range(count)]
    time.sleep(0.3)
    began = time.time()
    peer = Peer(connect())
    got = peer.response(GET)
    took = time.time() - began
    check(got is not None and got[0] == "HTTP/1.1 200 OK" and got[2] == b"Hello, World!\n", "request behind silent connections: %r" % (got,))
    check(took < ceiling, "request took %.2fs behind %d silent connections (ceiling %.1fs)" % (took, count, ceiling))
    # And a second one, on a fresh connection, with the silent ones still open.
    began = time.time()
    got = Peer(connect()).response(GET)
    again = time.time() - began
    check(got is not None and got[0] == "HTTP/1.1 200 OK" and again < ceiling, "second request: %r after %.2fs" % (got, again))
    for sock in silent:
        sock.close()
    print("OK %d silent connections open, real requests took %.2fs and %.2fs" % (count, took, again))

else:
    print("unknown mode " + mode)
    sys.exit(2)
PY
    tls_client() { python3 "$WORK/https_checks.py" "$@"; }
    HCLIENT_BUILT=0
    if SRC=scripts/https_client.m31 OUT="$WORK/https_client" bash scripts/build.sh >"$WORK/https_client.log" 2>&1; then
        HCLIENT_BUILT=1
    else
        bad "build scripts/https_client.m31" "$(tail -5 "$WORK/https_client.log")"
    fi

    # -- an Ed25519 server: curl, keep-alive, python ----------------------------
    if start_https ed "$FX/ed25519.chain" "$FX/ed25519.key"; then
        note "https server: listening on localhost:$HPORT (Ed25519 leaf, chain with CA)"
        ED_PORT=$HPORT
        if command -v curl >/dev/null 2>&1; then
            resp=$(curl -s -D "$WORK/hh1" -o "$WORK/hb1" -w '%{http_code}' --cacert "$FX/ca.pem" "https://localhost:$ED_PORT/")
            clen=$(tr -d '\r' <"$WORK/hh1" | grep -i '^content-length:' | awk '{print $2}')
            if [ "$resp" = "200" ] && [ "$(cat "$WORK/hb1")" = "Hello, World!" ] && [ "$clen" = "14" ]; then
                note "https (curl --cacert): 200, exact body, Content-Length: 14"
            else
                bad "https curl --cacert" "status=$resp body=[$(cat "$WORK/hb1")] content-length=[$clen]"
            fi
            counts=$(curl -s -o /dev/null -o /dev/null -o /dev/null -w '%{num_connects} ' --cacert "$FX/ca.pem" \
                "https://localhost:$ED_PORT/" "https://localhost:$ED_PORT/a" "https://localhost:$ED_PORT/b")
            if [ "$counts" = "1 0 0 " ]; then
                note "https keep-alive (curl): three requests, one TLS connection"
            else
                bad "https keep-alive (curl)" "num_connects per transfer: [$counts]"
            fi
            curl -s -o /dev/null --max-time 10 "https://localhost:$ED_PORT/" 2>"$WORK/curl_untrusted.err"
            rc=$?
            if [ "$rc" = 60 ] || [ "$rc" = 35 ]; then
                note "https: curl without the CA refuses the certificate (exit $rc)"
            else
                bad "https curl without --cacert" "exit $rc"
            fi
        else
            echo "skip https curl checks: curl not installed"
        fi
        if out=$(tls_client keepalive "$ED_PORT" tls "$FX/ca.pem" 2>&1); then
            note "https keep-alive (python ssl): $out"
        else
            bad "https keep-alive (python ssl)" "$out"
        fi
        out=$(printf '' | timeout 20 openssl s_client -tls1_2 -connect "localhost:$ED_PORT" -CAfile "$FX/ca.pem" 2>&1)
        if printf '%s' "$out" | grep -qi 'protocol version'; then
            note "https: openssl s_client -tls1_2 gets a protocol_version alert"
        else
            bad "https tls1.2" "$out"
        fi
    else
        bad "https server (Ed25519) start" "$(cat "$WORK/ed.log")"
    fi
    stop_https

    # -- an Ed25519 server: the standard library's own https client --------------
    # (it used to be unable to verify an Ed25519 certificate)
    if start_https ed25519std "$FX/ed25519.chain" "$FX/ed25519.key"; then
        if [ "$HCLIENT_BUILT" = 1 ]; then
            out=$("$WORK/https_client" "https://localhost:$HPORT/" "$FX/ca.pem" 2>&1)
            if [ "$out" = $'status 200\nbody 14' ]; then
                note "https (stdlib client, Trust.CaFile) verifies the Ed25519 certificate: 200, 14-byte body"
            else
                bad "https stdlib client on the Ed25519 server" "$out"
            fi
            out=$("$WORK/https_client" "https://localhost:$HPORT/" "$FX/other-ca.pem" 2>&1)
            if [ $? -ne 0 ] && printf '%s' "$out" | grep -q '^error '; then
                note "https (stdlib client): an Ed25519 certificate from another CA is refused"
            else
                bad "https stdlib client with the wrong CA (Ed25519)" "$out"
            fi
        fi
    else
        bad "https server (Ed25519, stdlib client) start" "$(cat "$WORK/ed25519std.log")"
    fi
    stop_https

    # -- DER certificates and keys -------------------------------------------------
    # der_serves NAME CHAIN KEY: a server loaded from these files answers python's
    # ssl (verifying against the CA), the stdlib client and, if present, curl.
    der_serves() {
        local name=$1 chain=$2 key=$3
        if start_https "$name" "$chain" "$key"; then
            local ok=1 detail=""
            out=$(tls_client keepalive "$HPORT" tls "$FX/ca.pem" 2>&1) || { ok=0; detail="python: $out"; }
            if [ "$HCLIENT_BUILT" = 1 ]; then
                out=$("$WORK/https_client" "https://localhost:$HPORT/" "$FX/ca.pem" 2>&1)
                [ "$out" = $'status 200\nbody 14' ] || { ok=0; detail="$detail stdlib client: $out"; }
            fi
            if command -v curl >/dev/null 2>&1; then
                out=$(curl -s --max-time 10 --cacert "$FX/ca.pem" "https://localhost:$HPORT/")
                [ "$out" = "Hello, World!" ] || { ok=0; detail="$detail curl: [$out]"; }
            fi
            if [ "$ok" = 1 ]; then
                note "https from DER ($name): python ssl, stdlib client and curl all verify and get 200"
            else
                bad "https from DER ($name)" "$detail"
            fi
        else
            bad "https server from DER ($name) start" "$(cat "$WORK/$name.log")"
        fi
        stop_https
    }
    der_serves der_p256_pkcs8 "$FX/p256.chain.der" "$FX/p256.pk8.der"
    der_serves der_p256_sec1 "$FX/p256.der" "$FX/p256.sec1.der"
    der_serves der_ed25519_pkcs8 "$FX/ed25519.chain.der" "$FX/ed25519.pk8.der"
    der_serves der_pem_chain_der_key "$FX/p256.chain" "$FX/p256.pk8.der"
    der_serves der_chain_pem_key "$FX/ed25519.chain.der" "$FX/ed25519.key"

    # -- a P-256 server: the standard library's own https client ---------------
    if start_https p256 "$FX/p256.pem" "$FX/p256.key"; then
        note "https server: listening on localhost:$HPORT (P-256 leaf)"
        if [ "$HCLIENT_BUILT" = 1 ]; then
            out=$("$WORK/https_client" "https://localhost:$HPORT/" "$FX/ca.pem" 2>&1)
            if [ "$out" = $'status 200\nbody 14' ]; then
                note "https (stdlib client, Trust.CaFile): 200, 14-byte body"
            else
                bad "https stdlib client" "$out"
            fi
            out=$("$WORK/https_client" "https://localhost:$HPORT/" "$FX/other-ca.pem" 2>&1)
            if [ $? -ne 0 ] && printf '%s' "$out" | grep -q '^error '; then
                note "https (stdlib client): a CA that did not sign the certificate is refused"
            else
                bad "https stdlib client with the wrong CA" "$out"
            fi
        fi
        if out=$(tls_client keepalive "$HPORT" tls "$FX/ca.pem" 2>&1); then
            note "https keep-alive on the P-256 server: $out"
        else
            bad "https keep-alive (P-256)" "$out"
        fi
        # limits: the same answers over TLS as over plain TCP
        plain_limits=$(tls_client limits "$PORT" plain 2>&1)
        tls_limits=$(tls_client limits "$HPORT" tls "$FX/ca.pem" 2>&1)
        if [ "$plain_limits" = "$tls_limits" ] && printf '%s' "$tls_limits" | grep -q 'requests on one connection: 1000 '; then
            note "https limits identical to plain (long header line, malformed request, 1000 requests/connection)"
        else
            bad "https limits" "plain:" "$plain_limits" "https:" "$tls_limits"
        fi
        # garbage and abuse
        if out=$(tls_client garbage "$HPORT" tls "$FX/ca.pem" 2>&1); then
            note "https bad handshakes: $out"
        else
            bad "https bad handshakes" "$out"
        fi
        if kill -0 "$HPID" 2>/dev/null; then
            note "https server still running after the bad handshakes"
        else
            bad "https server died" "$(tail -3 "$WORK/p256.log")"
        fi
    else
        bad "https server (P-256) start" "$(cat "$WORK/p256.log")"
    fi
    stop_https

    # -- silent and stalled clients: short timeout, a small worker pool ----------
    if start_https silent "$FX/p256.pem" "$FX/p256.key" --tls-handshake-timeout-ms 700 --tls-handshake-workers 2; then
        # 1 silent client: it never delays a good one.
        if out=$(tls_client silent "$HPORT" tls "$FX/ca.pem" 1 8 2>&1); then
            note "https silent client: $out"
        else
            bad "https silent client" "$out"
        fi
        # 8 silent clients on 2 workers: the good client waits its turn, bounded.
        if out=$(tls_client silent "$HPORT" tls "$FX/ca.pem" 8 20 2>&1); then
            note "https silent flood (8 on 2 workers): $out"
        else
            bad "https silent flood" "$out"
        fi
        if kill -0 "$HPID" 2>/dev/null && out=$(tls_client keepalive "$HPORT" tls "$FX/ca.pem" 2>&1); then
            note "https server healthy after the silent clients"
        else
            bad "https server after silent clients" "$(tail -3 "$WORK/silent.log")"
        fi
    else
        bad "https server (silent) start" "$(cat "$WORK/silent.log")"
    fi
    stop_https

    # -- silent clients no longer hold carriers -------------------------------------
    # Two carriers, four connections that open and send nothing: a real request
    # still completes at once, over plain HTTP and over https. (Sockets' timeouts
    # park the green thread only; they used to occupy the carrier in poll(2).)
    # The https server has more handshake workers than carriers on purpose: the
    # workers' bounded waits are exactly what used to take carriers, and the four
    # silent handshakes now sit on four workers with four more left.
    LANG_NUM_CARRIERS=2 start_https carriers_tls "$FX/p256.pem" "$FX/p256.key" --tls-handshake-workers 8
    if [ -n "${HPID:-}" ] && kill -0 "$HPID" 2>/dev/null; then
        if out=$(tls_client blocked "$HPORT" tls "$FX/ca.pem" 4 1 2>&1); then
            note "https, LANG_NUM_CARRIERS=2: $out"
        else
            bad "https silent clients on 2 carriers" "$out"
        fi
    else
        bad "https server (2 carriers) start" "$(cat "$WORK/carriers_tls.log")"
    fi
    stop_https
    PLAIN_PORT=$((20000 + (RANDOM % 20000)))
    LANG_NUM_CARRIERS=2 "$BIN" --port "$PLAIN_PORT" --host 127.0.0.1 >"$WORK/carriers_plain.log" 2>&1 &
    HPIDS+=("$!")
    sleep 0.5
    if out=$(tls_client blocked "$PLAIN_PORT" plain "" 4 1 2>&1); then
        note "plain http, LANG_NUM_CARRIERS=2: $out"
    else
        bad "plain silent clients on 2 carriers" "$out"
    fi
    stop_https

    # -- startup refusals ---------------------------------------------------------
    refuse() { # refuse NAME EXPECTED-EXIT PATTERN args...
        local name=$1 want=$2 pattern=$3
        shift 3
        timeout 10 "$BIN" --port "$((20000 + (RANDOM % 20000)))" --host localhost "$@" >"$WORK/refuse.out" 2>&1
        local rc=$?
        if [ "$rc" = "$want" ] && grep -q -- "$pattern" "$WORK/refuse.out" && no_key_material "$WORK/refuse.out"; then
            note "startup refused ($name): exit $rc"
        else
            bad "startup refusal: $name" "exit $rc (want $want), pattern [$pattern]" "$(head -5 "$WORK/refuse.out")"
        fi
    }
    refuse "key is not the certificate's" 1 'does not match' --tls-cert "$FX/p256.pem" --tls-key "$FX/stranger.key"
    refuse "Ed25519 key for a P-256 certificate" 1 'does not match' --tls-cert "$FX/p256.pem" --tls-key "$FX/ed25519.key"
    refuse "RSA key" 1 'cannot sign with' --tls-cert "$FX/p256.pem" --tls-key "$FX/rsa.key"
    refuse "encrypted key" 1 'encrypted' --tls-cert "$FX/p256.pem" --tls-key "$FX/encrypted.key"
    refuse "garbage key file" 1 'no usable private key' --tls-cert "$FX/p256.pem" --tls-key "$FX/garbage.key"
    refuse "key file used as the certificate" 1 'no valid PEM certificate' --tls-cert "$FX/p256.key" --tls-key "$FX/p256.key"
    refuse "DER key is not the certificate's" 1 'does not match' --tls-cert "$FX/p256.der" --tls-key "$FX/stranger.pk8.der"
    refuse "Ed25519 DER key for a P-256 DER certificate" 1 'does not match' --tls-cert "$FX/p256.der" --tls-key "$FX/ed25519.pk8.der"
    refuse "truncated DER key" 1 'no usable private key' --tls-cert "$FX/p256.der" --tls-key "$FX/truncated.pk8.der"
    refuse "DER key used as the certificate" 1 'could not be parsed' --tls-cert "$FX/p256.pk8.der" --tls-key "$FX/p256.pk8.der"
    refuse "missing certificate file" 1 'could not be read' --tls-cert "$WORK/nowhere.pem" --tls-key "$FX/p256.key"
    refuse "--tls-cert without --tls-key" 2 'go together' --tls-cert "$FX/p256.pem"
    refuse "--tls-key without --tls-cert" 2 'go together' --tls-key "$FX/p256.key"
    refuse "--tls-handshake-timeout-ms 0" 2 'must be at least 1' --tls-cert "$FX/p256.pem" --tls-key "$FX/p256.key" --tls-handshake-timeout-ms 0
    refuse "--tls-handshake-workers 0" 2 'must be at least 1' --tls-cert "$FX/p256.pem" --tls-key "$FX/p256.key" --tls-handshake-workers 0

    # -- no key material anywhere a server writes ---------------------------------
    if no_key_material "$WORK"/*.log; then
        note "no key material in any server output"
    else
        bad "key material in a server log" "$(head -3 "$WORK/p256.log")"
    fi
    if kill -0 "$server_pid" 2>/dev/null && [ "$(tls_client keepalive "$PORT" plain 2>&1 | cut -c1-2)" = OK ]; then
        note "plain http is unchanged: still 200 beside the https tests"
    else
        bad "plain http after https tests"
    fi
fi

# --- summary ------------------------------------------------------------

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
