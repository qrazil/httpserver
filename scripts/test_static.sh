#!/usr/bin/env bash
# Tests for `httpserver --root DIR` (static file serving).
#
#   M31_ROOT=/path/to/m31 bash scripts/test_static.sh [oracle|fuzz|stream|https|cli]...
#
# Builds ./httpserver unless HTTPSERVER_BIN points at one. Every check runs
# against a real server on a loopback port with a disposable tree (see
# static_fixture.py); nothing is mocked and nothing leaves 127.0.0.1.
# Portable to bash 3.2 and BSD tools: no associative arrays, no mapfile, no
# GNU-only flags; the logic lives in Python 3's standard library.
set -uo pipefail
cd "$(dirname "$0")/.."
SCRIPTS=$(pwd)/scripts
export PYTHONDONTWRITEBYTECODE=1

WORK=$(mktemp -d)
pass=0
fail=0
pids=""

note() { printf '\033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '\033[31mFAIL\033[0m %s\n' "$1"; shift; printf '%s\n' "$@" | sed 's/^/     /'; fail=$((fail + 1)); }

cleanup() {
    for pid in $pids; do kill "$pid" >/dev/null 2>&1; wait "$pid" 2>/dev/null; done
    rm -rf "$WORK"
}
trap cleanup EXIT

for tool in python3 curl; do
    command -v "$tool" >/dev/null 2>&1 || { echo "skip static tests: need $tool"; exit 0; }
done

if [ -n "${HTTPSERVER_BIN:-}" ]; then
    BIN=$HTTPSERVER_BIN
else
    if ! bash scripts/build.sh >"$WORK/build.log" 2>&1; then
        bad "build" "$(cat "$WORK/build.log")"
        exit 1
    fi
    BIN=./httpserver
fi

free_port() { echo $((20000 + (RANDOM % 20000))); }

# start NAME HOST [flags...] -> PORT, SPID. Waits until the port accepts.
start() {
    local name=$1 host=$2
    shift 2
    PORT=$(free_port)
    "$BIN" --port "$PORT" --host "$host" "$@" >"$WORK/$name.log" 2>&1 &
    SPID=$!
    pids="$pids $SPID"
    local tries=0
    while [ "$tries" -lt 100 ]; do
        if (exec 3<>"/dev/tcp/$host/$PORT") 2>/dev/null; then
            exec 3>&-
            return 0
        fi
        kill -0 "$SPID" 2>/dev/null || return 1
        sleep 0.05
        tries=$((tries + 1))
    done
    return 1
}

stop() { kill "$1" >/dev/null 2>&1; wait "$1" 2>/dev/null; }

# run_py NAME script args... : run a Python check file, fold its counts in.
run_py() {
    local name=$1
    shift
    (cd "$SCRIPTS" && python3 "$@") >"$WORK/$name.out" 2>&1
    local rc=$?
    grep -v '^py-summary' "$WORK/$name.out" | grep -v '^ok ' | sed 's/^/  /' | head -60
    local ok_n fail_n
    ok_n=$(grep -c '^ok ' "$WORK/$name.out")
    fail_n=$(grep -c '^FAIL ' "$WORK/$name.out")
    pass=$((pass + ok_n))
    fail=$((fail + fail_n))
    if [ "$rc" != 0 ] && [ "$fail_n" = 0 ]; then
        bad "$name crashed" "$(tail -15 "$WORK/$name.out")"
    fi
    printf '%s: %s ok, %s failed\n' "$name" "$ok_n" "$fail_n"
}

want() { # want NAME : whether this group was asked for (all by default)
    [ "$#" -ge 1 ] || return 0
    [ -z "${GROUPS_WANTED:-}" ] && return 0
    case " $GROUPS_WANTED " in *" $1 "*) return 0 ;; esac
    return 1
}
GROUPS_WANTED="$*"

BIGMIB=${STATIC_BIG_MIB:-64}
OUTER=$WORK/outer
ROOT=$OUTER/root
python3 scripts/static_fixture.py "$OUTER" "$BIGMIB" || { bad "fixture"; exit 1; }
note "fixture: $(ls "$ROOT" | wc -l | tr -d ' ') entries, ${BIGMIB} MiB big.bin"

# --- the CLI ------------------------------------------------------------
if want cli; then
    refuse() { # refuse NAME PATTERN args...
        local name=$1 pattern=$2
        shift 2
        timeout 10 "$BIN" --port "$(free_port)" --host 127.0.0.1 "$@" >"$WORK/refuse.out" 2>&1
        local rc=$?
        if [ "$rc" = 2 ] && grep -q -- "$pattern" "$WORK/refuse.out"; then
            note "startup refused ($name): exit 2"
        else
            bad "startup refusal: $name" "exit $rc, pattern [$pattern]" "$(head -3 "$WORK/refuse.out")"
        fi
    }
    refuse "--root is not a directory" 'not a directory' --root "$ROOT/hello.txt"
    refuse "--root does not exist" 'not a directory' --root "$WORK/nowhere"
    refuse "--listing without --root" 'need --root' --listing
    refuse "--dotfiles without --root" 'need --root' --dotfiles
    refuse "--cache without --root" 'need --root' --cache 5
    refuse "--index without --root" 'need --root' --index home.html
    refuse "--index with a slash" 'plain file name' --root "$ROOT" --index a/b
    refuse "--index .." 'plain file name' --root "$ROOT" --index ..
    refuse "--cache -1" 'must be 0 or more' --root "$ROOT" --cache -1
    if "$BIN" --help | grep -q -- '--root' && "$BIN" --help | grep -q -- '--listing'; then
        note "--help lists --root and --listing"
    else
        bad "--help lists the static flags"
    fi
fi

if want oracle; then
    PYPORT=$(free_port)
    (cd "$ROOT" && exec python3 -m http.server "$PYPORT" --bind 127.0.0.1 --directory "$ROOT") >"$WORK/pyserver.log" 2>&1 &
    PYPID=$!
    pids="$pids $PYPID"
    tries=0
    while [ "$tries" -lt 100 ] && ! (exec 3<>"/dev/tcp/127.0.0.1/$PYPORT") 2>/dev/null; do sleep 0.05; tries=$((tries + 1)); done
    if start oracle 127.0.0.1 --root "$ROOT" --cache 0; then
        run_py oracle static_oracle.py "$PORT" "$PYPORT" "$ROOT"
        stop "$SPID"
    else
        bad "oracle server start" "$(cat "$WORK/oracle.log")"
    fi
    stop "$PYPID"
fi

if want fuzz; then
    if start fuzz 127.0.0.1 --root "$ROOT"; then
        run_py fuzz static_fuzz.py "$PORT" "$ROOT"
        if kill -0 "$SPID" 2>/dev/null; then
            note "fuzz: server process still running"
        else
            bad "fuzz: server process died" "$(tail -5 "$WORK/fuzz.log")"
        fi
        stop "$SPID"
    else
        bad "fuzz server start" "$(cat "$WORK/fuzz.log")"
    fi
fi

if want stream; then
    if start stream 127.0.0.1 --root "$ROOT"; then
        run_py stream static_stream.py "$PORT" "$ROOT" "$SPID"
        stop "$SPID"
    else
        bad "stream server start" "$(cat "$WORK/stream.log")"
    fi
fi

if want policy; then
    if start pol_a 127.0.0.1 --root "$ROOT" --listing; then
        PA=$PORT; PIDA=$SPID
        start pol_b 127.0.0.1 --root "$ROOT" --listing --dotfiles --index hello.txt; PB=$PORT; PIDB=$SPID
        start pol_c 127.0.0.1 --root "$ROOT" --cache 3600; PC=$PORT; PIDC=$SPID
        run_py policy static_policy.py "$PA" "$PB" "$PC" "$ROOT"
        stop "$PIDA"; stop "$PIDB"; stop "$PIDC"
    else
        bad "policy server start" "$(cat "$WORK/pol_a.log")"
    fi
fi

if want https; then
    if ! command -v openssl >/dev/null 2>&1; then
        echo "skip static https tests: need openssl"
    else
        FX=$WORK/fx
        mkdir -p "$FX"
        (
            cd "$FX" || exit 1
            openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out ca.key
            openssl req -x509 -new -key ca.key -sha256 -days 30 -subj /CN=static-test-ca \
                -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign -out ca.pem
            openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out leaf.key
            openssl req -new -key leaf.key -subj /CN=localhost -out leaf.csr
            printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=serverAuth\n' >leaf.ext
            openssl x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 30 -extfile leaf.ext -out leaf.pem
            cat leaf.pem ca.pem >chain.pem
        ) >"$WORK/fx.log" 2>&1
        if [ ! -s "$FX/chain.pem" ]; then
            bad "https fixture" "$(tail -5 "$WORK/fx.log")"
        elif start https localhost --root "$ROOT" --listing --tls-cert "$FX/chain.pem" --tls-key "$FX/leaf.key"; then
            HP=$PORT; HPID=$SPID
            hbase="https://localhost:$HP"
            ca="$FX/ca.pem"
            body=$(curl -sS --cacert "$ca" "$hbase/hello.txt")
            [ "$body" = "Hello, file!" ] && note "https: curl --cacert GET /hello.txt" || bad "https GET" "$body"
            code=$(curl -sS --cacert "$ca" -o /dev/null -w '%{http_code}' -I "$hbase/hello.txt")
            [ "$code" = 200 ] && note "https: HEAD 200" || bad "https HEAD" "$code"
            etag=$(curl -sS --cacert "$ca" -D - -o /dev/null "$hbase/hello.txt" | tr -d '\r' | awk -F': ' 'tolower($1)=="etag"{print $2}')
            code=$(curl -sS --cacert "$ca" -o /dev/null -w '%{http_code}' -H "If-None-Match: $etag" "$hbase/hello.txt")
            [ "$code" = 304 ] && note "https: If-None-Match -> 304" || bad "https 304" "$code [$etag]"
            part=$(curl -sS --cacert "$ca" -H 'Range: bytes=7-10' "$hbase/hello.txt")
            [ "$part" = "file" ] && note "https: Range bytes=7-10 -> 'file'" || bad "https range" "$part"
            code=$(curl -sS --cacert "$ca" -o /dev/null -w '%{http_code}' --path-as-is "$hbase/../secret.txt")
            [ "$code" = 400 ] && note "https: /../secret.txt -> 400" || bad "https traversal" "$code"
            code=$(curl -sS --cacert "$ca" -o /dev/null -w '%{http_code}' "$hbase/link-file")
            [ "$code" = 403 ] && note "https: symlink -> 403" || bad "https symlink" "$code"
            code=$(curl -sS --cacert "$ca" -o /dev/null -w '%{http_code}' "$hbase/.git/config")
            [ "$code" = 404 ] && note "https: dotfile -> 404" || bad "https dotfile" "$code"
            curl -sS --cacert "$ca" -o "$WORK/mid.dl" "$hbase/mid.bin"
            if cmp -s "$WORK/mid.dl" "$ROOT/mid.bin"; then note "https: curl downloads mid.bin byte-exact"; else bad "https mid.bin"; fi
            curl -sS --cacert "$ca" "$hbase/noindex/?json" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["path"]=="/noindex/"' \
                && note "https: JSON directory listing" || bad "https listing"
            export STATIC_TLS_CA="$ca"
            STREAM_BIG=tls.bin run_py https_stream static_stream.py "$HP" "$ROOT" "$HPID" "$ca"
            FUZZ_LISTING=1 FUZZ_N=400 run_py https_fuzz static_fuzz.py "$HP" "$ROOT"
            unset STATIC_TLS_CA
            if kill -0 "$HPID" 2>/dev/null; then note "https: server process still running"; else bad "https server died" "$(tail -5 "$WORK/https.log")"; fi
            stop "$HPID"
        else
            bad "https server start" "$(cat "$WORK/https.log")"
        fi
    fi
fi

echo
echo "static: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
