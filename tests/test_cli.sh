#!/usr/bin/env bash
# httpserver's command line: Oro's grammar (m31's docs/cli-conventions.md): every
# option, its short and long forms, the refusals, the generated --help,
# --version and --completions, and that each spelling really starts a server.
#
#   M31_ROOT=/path/to/m31 bash tests/test_cli.sh              (builds ./httpserver)
#   HTTPSERVER_BIN=./httpserver bash tests/test_cli.sh        (uses a built one)
#
# Servers it starts are killed by pid. macOS-safe: bash 3.2, BSD tools, no GNU
# timeout, no /tmp paths (mktemp), no `date +%s%N`.
set -uo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
pids=""
cleanup() {
    for pid in $pids; do
        kill "$pid" >/dev/null 2>&1
        wait "$pid" 2>/dev/null
    done
    rm -rf "$WORK"
}
trap cleanup EXIT
pass=0
fail=0
note() { printf '\033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '\033[31mFAIL\033[0m %s\n' "$1"; shift; printf '%s\n' "$@" | sed 's/^/     /'; fail=$((fail + 1)); }

BIN=${HTTPSERVER_BIN:-}
if [ -z "$BIN" ]; then
    if ! bash scripts/build.sh >"$WORK/build.log" 2>&1; then
        bad "build" "$(tail -5 "$WORK/build.log")"
        exit 1
    fi
    BIN=./httpserver
fi

run() {
    "$BIN" "$@" >"$WORK/out" 2>"$WORK/err" </dev/null
    code=$?
    out=$(cat "$WORK/out")
    err=$(cat "$WORK/err")
}
expect() {
    local label=$1 want=$2 so=${3:-} se=${4:-}
    if [ "$code" != "$want" ]; then
        bad "$label" "exit $code, want $want" "stdout: $out" "stderr: $err"
    elif [ -n "$so" ] && [[ "$out" != *"$so"* ]]; then
        bad "$label" "stdout lacks: $so" "stdout: $out"
    elif [ -n "$se" ] && [[ "$err" != *"$se"* ]]; then
        bad "$label" "stderr lacks: $se" "stderr: $err"
    else
        note "$label"
    fi
}

# --- help, version, completions ---------------------------------------------------
run --help; expect "--help" 0 "usage: httpserver [options]"
for want in "--p, --port PORT" "--r, --root DIR" "--host HOST" "--backlog N" "--tls-cert FILE" "--tls-key FILE" \
    "--tls-handshake-timeout-ms MS" "--tls-handshake-workers N" "--index NAME" "--listing" "--dotfiles" \
    "--cache SECONDS" "--help" "--version" "--completions SHELL" "(default 8080)" "(default 0.0.0.0)" "exit status:"; do
    run --help
    if [[ "$out" == *"$want"* ]]; then note "--help lists: $want"; else bad "--help lacks: $want" "$out"; fi
done
run --version; expect "--version" 0 "httpserver 0."
run --completions bash; expect "--completions bash" 0 "complete -o filenames -F _httpserver_complete httpserver"
if printf '%s\n' "$out" | bash -n 2>"$WORK/syntax"; then note "--completions bash is valid bash"; else bad "bash completion syntax" "$(cat "$WORK/syntax")"; fi
run --completions zsh;  expect "--completions zsh" 0 "#compdef httpserver"
run --completions fish; expect "--completions fish" 0 "complete -c httpserver -l port"
run --completions csh;  expect "--completions csh" 2 "" "'--completions' needs bash, zsh or fish, and got 'csh'"

# --- Oro's refusals: stderr, exit 2 --------------------------------------------------
run -h;        expect "-h is refused" 2 "" "write '--help'"
run -help;     expect "-help is refused" 2 "" "write '--help'"
run help;      expect "help is refused" 2 "" "'help' is an option here, not a command -- write '--help'"
run --h;       expect "--h is refused" 2 "" "help has one spelling, and it is '--help'"
run --;        expect "a lone -- is refused" 2 "" "'--' has no meaning here"
run -p 80;     expect "-p is a command, and there is none" 2 "" "takes no commands"
run --prot 80;  expect "a mistyped option is suggested" 2 "" "did you mean '--port'?"
run --por 80;  expect "an abbreviation is suggested, never accepted" 2 "" "did you mean '--port'?"
run --port abc; expect "--port abc" 2 "" "'--port' needs a whole number, and got 'abc'"
run --port;    expect "--port at the end" 2 "" "'--port' needs a value and is the last argument"
run --port 1 --port 2; expect "--port twice" 2 "" "was given more than once and takes a single value"
run --port 70000; expect "--port 70000" 2 "" "--port 70000: a port is 0..65535"
run --backlog 0;  expect "--backlog 0" 2 "" "--backlog 0: must be at least 1"
run --tls-cert c.pem; expect "--tls-cert alone" 2 "" "--tls-cert and --tls-key go together"
run --listing;    expect "--listing needs --root" 2 "" "need --root"
run --root "$WORK/nowhere"; expect "--root not a directory" 2 "" "not a directory"
run --quiet;      expect "an unknown option" 2 "" "unknown option '--quiet'"
run extra;        expect "an operand" 2 "" "takes no arguments of its own, and got 'extra'"
run --listing=1;  expect "a flag takes no value" 2 "" "is a flag and takes no value"
run --p;          expect "--p at the end" 2 "" "'--p' needs a value and is the last argument"
[ -z "$out" ] && note "usage errors print nothing on stdout" || bad "usage error wrote stdout" "$out"

# --- every spelling starts a server -------------------------------------------------------
PORT=$((20000 + (RANDOM % 20000)))
start() {
    "$BIN" "$@" >"$WORK/server.log" 2>&1 </dev/null &
    pid=$!
    pids="$pids $pid"
    up=0
    local tries=0
    while [ "$tries" -lt 100 ]; do
        if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
            exec 3>&-
            up=1
            break
        fi
        sleep 0.05
        tries=$((tries + 1))
    done
}
stop() {
    kill "$pid" >/dev/null 2>&1
    wait "$pid" 2>/dev/null
}
check_up() {
    if [ "$up" = 1 ]; then note "$1"; else bad "$1" "$(cat "$WORK/server.log")"; fi
    stop
}
start --port "$PORT" --host 127.0.0.1;   check_up "--port PORT listens"
start "--port=$PORT" --host 127.0.0.1;   check_up "--port=PORT listens"
start --p "$PORT" --host 127.0.0.1;      check_up "--p PORT listens"
mkdir -p "$WORK/site"
echo hello >"$WORK/site/index.html"
start --port "$PORT" --host 127.0.0.1 --r "$WORK/site";        check_up "--r DIR serves a directory"
start --port "$PORT" --host 127.0.0.1 --root "$WORK/site";     check_up "--root DIR serves a directory"
start --port "$PORT" --host 127.0.0.1 "--root=$WORK/site" --listing --dotfiles --cache 60 --index index.html
check_up "--root=DIR with --listing --dotfiles --cache --index"
start --port "$PORT" --host 127.0.0.1 --backlog 128;           check_up "--backlog 128 listens"
if command -v curl >/dev/null 2>&1; then
    start --port "$PORT" --host 127.0.0.1 --root "$WORK/site"
    if [ "$(curl -s "http://127.0.0.1:$PORT/")" = hello ]; then note "--root serves index.html"; else bad "--root did not serve index.html"; fi
    stop
fi

# --- install.sh ----------------------------------------------------------------
run_sh() {
    sh install.sh "$@" >"$WORK/out" 2>"$WORK/err" </dev/null
    code=$?
    out=$(cat "$WORK/out")
    err=$(cat "$WORK/err")
}
run_sh --help; expect "install.sh --help" 0 "usage: sh install.sh [options] [-uninstall]"
run_sh --version; expect "install.sh --version" 0 "installer"
run_sh -h;     expect "install.sh: -h is refused" 2 "" "write '--help'"
run_sh help;   expect "install.sh: help is refused" 2 "" "write '--help'"
run_sh --;     expect "install.sh: a lone -- is refused" 2 "" "'--' has no meaning here"
run_sh --prefx /x; expect "install.sh: typo suggests" 2 "" "did you mean '--prefix'?"
run_sh -unistall;  expect "install.sh: a mistyped command is suggested" 2 "" "did you mean '-uninstall'?"
run_sh --libc foo; expect "install.sh: bad --libc" 2 "" "needs gnu or musl, and got 'foo'"
run_sh --prefix;   expect "install.sh: --prefix at the end" 2 "" "needs a value and is the last argument"
run_sh extra;  expect "install.sh: an operand" 2 "" "unexpected argument 'extra'"
for spelling in "-uninstall --prefix $WORK/i1" "-u --prefix=$WORK/i2" "-u --p $WORK/i3"; do
    # shellcheck disable=SC2086
    run_sh $spelling
    expect "install.sh $(printf '%s' "$spelling" | sed "s#$WORK#.#g")" 0 "removed"
done
run_sh --uninstall --prefix "$WORK/i4"; expect "install.sh --uninstall (the old spelling) works and warns" 0 "removed" "deprecated"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
