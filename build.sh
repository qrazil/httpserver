#!/usr/bin/env bash
# Build httpserver into ./httpserver.
#
#   M31_ROOT=/path/to/m31 bash build.sh          -O2, warnings are errors
#   M31_ROOT=/path/to/m31 CC=clang bash build.sh
#
# This app is one `.m31` file, compiled by the m31 compiler (m31c) and then
# linked, as ordinary C, against the m31 RUNTIME's own source files
# (runtime/rt.c, runtime/scheduler.c, the platform reactor and context-
# switch files) -- there is no pre-built runtime library to link against
# instead, so this script needs both:
#
#   - LANGC: the m31c compiler binary (env var, default ./m31c beside this
#     script -- where a downloaded release binary would land).
#   - M31_ROOT: a directory containing the m31 project's own config.sh and
#     runtime/ (its source files, plus runtime/arch.sh, which this script
#     uses to pick the right reactor backend and context-switch file for
#     the host it's running on) -- a checkout of github.com/qrazil/m31 at
#     the same version LANGC was built from, or an extracted release's
#     runtime-sdk bundle, whichever this repo's own CI (or you, locally)
#     has on hand. No default: get this wrong and the build either doesn't
#     find runtime/rt.c at all, or links against a mismatched version of
#     it, so a missing M31_ROOT is a clear error instead of a guess.
set -uo pipefail
cd "$(dirname "$0")"

if [ -z "${M31_ROOT:-}" ]; then
    echo "M31_ROOT is not set -- point it at a checkout of github.com/qrazil/m31" \
         "(or an extracted runtime-sdk bundle) matching the m31c version you're" \
         "building with. See this script's own header comment." >&2
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
OUT=${OUT:-httpserver}
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

if [ ! -x "$LANGC" ]; then
    echo "compiler not found or not executable: $LANGC" >&2
    exit 1
fi

"$LANGC" --emit-c "main.$LANG_EXT" -o "$W/httpserver.c" || exit 1
# RT_REACTOR_C/RT_CTX_ASM (from runtime/arch.sh above) are paths relative to
# M31_ROOT, not to this script's own directory -- prefix them before use.
# The same flags this project's own run.sh holds the corpus to: the emitted
# C must be clean.
"$CC" "$OPT" -ffp-contract=off -Wall -Wextra -Werror -I "$M31_ROOT/runtime" -pthread \
      -o "$OUT" "$W/httpserver.c" \
      "$M31_ROOT/runtime/rt.c" "$M31_ROOT/runtime/scheduler.c" \
      "$M31_ROOT/$RT_REACTOR_C" "$M31_ROOT/$RT_CTX_ASM" || exit 1
echo "built $OUT"
