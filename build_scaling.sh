#!/usr/bin/env bash
# Build httpserver into ./httpserver_scaling -- identical to build.sh's
# ./httpserver EXCEPT it also links greenthread_probe.c (a SIGUSR1-based,
# read-only introspection probe, see that file's own header comment) for
# use by SCALING.md's ramping concurrency test. The shipped build.sh/
# ./httpserver binary used for BENCHMARK.md is untouched by this script.
#
#   M31_ROOT=/path/to/m31 bash build_scaling.sh
#
# See build.sh's own header for what M31_ROOT/LANGC need to point at.
set -uo pipefail
cd "$(dirname "$0")"

if [ -z "${M31_ROOT:-}" ]; then
    echo "M31_ROOT is not set -- see build.sh's own header comment." >&2
    exit 1
fi
if [ ! -f "$M31_ROOT/config.sh" ] || [ ! -d "$M31_ROOT/runtime" ]; then
    echo "M31_ROOT=$M31_ROOT does not look like an m31 checkout" \
         "(expected $M31_ROOT/config.sh and $M31_ROOT/runtime/)" >&2
    exit 1
fi

. "$M31_ROOT/config.sh"
. "$M31_ROOT/runtime/arch.sh"

LANGC=${LANGC:-./m31c}
CC=${CC:-gcc}
OPT=${OPT:--O2}
OUT=${OUT:-httpserver_scaling}
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

if [ ! -x "$LANGC" ]; then
    echo "compiler not found or not executable: $LANGC" >&2
    exit 1
fi

"$LANGC" --emit-c "main.$LANG_EXT" -o "$W/httpserver.c" || exit 1
"$CC" "$OPT" -ffp-contract=off -Wall -Wextra -Werror -I "$M31_ROOT/runtime" -pthread \
      -o "$OUT" "$W/httpserver.c" greenthread_probe.c \
      "$M31_ROOT/runtime/rt.c" "$M31_ROOT/runtime/scheduler.c" \
      "$M31_ROOT/$RT_REACTOR_C" "$M31_ROOT/$RT_CTX_ASM" || exit 1
echo "built $OUT"
