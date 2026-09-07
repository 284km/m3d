#!/bin/sh
# scripts/linalg_check.sh — three readers on the same arithmetic, each seeing something
# the others cannot.
#
#   1. THE FOUR BACKENDS AGAINST EACH OTHER, exactly. src/linalg.mere uses only the five
#      operations IEEE-754 requires to be correctly rounded (+ - * / and sqrt), so the
#      interpreter, C, LLVM and Wasm must print the SAME BITS. No oracle is involved: they
#      are each other's, and a single differing bit is a compiler bug or a mistake in the
#      library, never a rounding story. This is the check that would catch a backend, and
#      it is the reason the trigonometry lives in a separate part of the file.
#
#   2. A SECOND IMPLEMENTATION, by a different route. Four backends running one source
#      agree about a wrong formula as readily as a right one. scripts/gen_linalg_expected.py
#      computes the same quantities with Gauss-Jordan where this uses Laplace, a quaternion
#      sandwich where this uses the closed form, a frustum where this writes the entries.
#      Different rounding, so that one is in ulps and not in bits.
#
#   3. THE PROPERTIES, with no second implementation at all. test/linalg_props.mere asks
#      whether a cross product is perpendicular to its inputs and whether a rotation
#      preserves length -- facts about the answer, which no amount of agreement between
#      implementations establishes.
#
# A backend whose toolchain is absent is SKIPPED WITH A PRINTED REASON. A skip is a real
# weakening -- the exact check above is only as strong as the number of backends in it --
# so it is output, not silence, and `checked` is printed so a run that compared nothing
# cannot read as a pass.
#
# Usage:  MERE=/path/to/mere.exe [MERE_SRC=/path/to/mere/checkout] sh scripts/linalg_check.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-mere}"
command -v "$MERE" >/dev/null 2>&1 || { echo "linalg_check: no mere — set MERE=..." >&2; exit 1; }
CC="${CC:-clang}"
T="${TMPDIR:-/tmp}/m3d_linalg.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
cd "$ROOT"

fail=0
backends="interp"

run_interp() { "$MERE" "$1" 2>&1; }
run_c() {
  "$MERE" -c "$1" > "$T/x.c" 2>"$T/err" || return 1
  "$CC" -O2 -w "$T/x.c" -o "$T/x" -lm 2>>"$T/err" || return 1
  "$T/x" 2>&1
}
run_llvm() {
  "$MERE" -ll "$1" > "$T/x.ll" 2>"$T/err" || return 1
  "$CC" -O2 -w "$T/x.ll" -o "$T/xl" -lm 2>>"$T/err" || return 1
  "$T/xl" 2>&1
}
run_wasm() {
  "$MERE" -w "$1" > "$T/x.wat" 2>"$T/err" || return 1
  wat2wasm --enable-tail-call --enable-threads "$T/x.wat" -o "$T/x.wasm" 2>>"$T/err" || return 1
  node "$MERE_SRC/scripts/run_wasm.js" "$T/x.wasm" 2>&1
}

have_c=0; command -v "$CC" >/dev/null 2>&1 && have_c=1 || echo "linalg_check: SKIP c — no $CC"
have_llvm=$have_c
have_wasm=0
if [ -n "${MERE_SRC:-}" ] && [ -f "$MERE_SRC/scripts/run_wasm.js" ] \
   && command -v wat2wasm >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
  have_wasm=1
else
  echo "linalg_check: SKIP wasm — needs MERE_SRC=<mere checkout> plus wat2wasm and node"
fi

# ---- 1. the four backends, exactly ----------------------------------------------------
for prog in test/linalg_dump.mere test/linalg_props.mere; do
  name=$(basename "$prog" .mere)
  ref=$(run_interp "$prog") || { echo "linalg_check: $name did not run on interp"; echo "$ref"; fail=1; continue; }
  n=1
  for be in c llvm wasm; do
    case "$be" in
      c)    [ "$have_c" = 1 ] || continue ;;
      llvm) [ "$have_llvm" = 1 ] || continue ;;
      wasm) [ "$have_wasm" = 1 ] || continue ;;
    esac
    out=$("run_$be" "$prog") || { echo "linalg_check: $name did not build/run on $be"; sed 's/^/    /' "$T/err" | head -4; fail=1; continue; }
    n=$((n + 1))
    if [ "$out" != "$ref" ]; then
      echo "linalg_check: $name DIFFERS on $be"
      printf '%s\n' "$ref" > "$T/ref.txt"; printf '%s\n' "$out" > "$T/got.txt"
      diff "$T/ref.txt" "$T/got.txt" | head -8
      fail=1
    fi
  done
  echo "linalg_check: $name — $n backend(s) byte-identical"
  [ "$n" -ge 2 ] || { echo "linalg_check: only one backend ran, which compares nothing"; fail=1; }
  case "$ref" in *MISMATCH*) echo "linalg_check: $name reported a failed property"; fail=1 ;; esac
done

# ---- 2. the second implementation ------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  "$MERE" test/linalg_dump.mere 2>/dev/null | python3 scripts/gen_linalg_expected.py || fail=1
else
  echo "linalg_check: SKIP the second implementation — no python3"
fi

[ "$fail" = 0 ] && echo "PASS linalg_check" || echo "FAIL linalg_check"
exit $fail
