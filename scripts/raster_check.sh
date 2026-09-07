#!/bin/sh
# scripts/raster_check.sh — three readers on the same coverage.
#
#   1. THE PROPERTIES, with no reference at all (test/raster_props.mere). Two triangles
#      sharing an edge cover every pixel along it EXACTLY ONCE -- twice double-blends and
#      shows as a bright seam, zero times shows as background through solid geometry. No
#      amount of agreement with another rasterizer establishes that; two implementations
#      of the same wrong rule agree perfectly.
#
#      It is also blind to a whole class: coverage is all it looks at, so a rasterizer
#      that covers the right pixels and puts the wrong colours in them passes. Measured by
#      planting one -- perspective correction removed -- which left this green.
#
#   2. EXACT RATIONAL COVERAGE (scripts/raster_oracle.py). Which pixels a triangle covers
#      is a question about exact geometry, and `fractions.Fraction` answers it with no
#      floating point at all, so a disagreement is a mistake in the geometry rather than a
#      last-bit difference. This is the one that caught the perspective poison. The colour
#      and depth VALUES it follows in float by the same formulae, which is a transcription
#      and is labelled as one in that file.
#
#   3. THE FOUR BACKENDS against each other, exactly -- run by scripts/check.sh over the
#      same dump, so a backend rather than the algorithm is what that one can see.
#
# Usage:  MERE=/path/to/mere.exe sh scripts/raster_check.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-mere}"
command -v "$MERE" >/dev/null 2>&1 || { echo "raster_check: no mere — set MERE=..." >&2; exit 1; }
cd "$ROOT"
fail=0

out=$("$MERE" test/raster_props.mere 2>&1) || { echo "raster_check: raster_props did not run"; echo "$out" | head -3; fail=1; }
case "$out" in
  *"raster_props: ok"*) echo "raster_check: the coverage properties hold (exactly-once on a shared edge, and the rest)" ;;
  *) echo "$out" | grep MISMATCH | head -6; echo "raster_check: a coverage property failed"; fail=1 ;;
esac

if command -v python3 >/dev/null 2>&1; then
  res=$("$MERE" test/raster_dump.mere 2>&1 | python3 scripts/raster_oracle.py 2>&1)
  echo "$res" | sed 's/^/  /' | head -6
  case "$res" in *FAIL*) fail=1 ;; esac
else
  echo "raster_check: SKIP the exact-rational reference — no python3"
fi

[ "$fail" = 0 ] && echo "PASS raster_check" || echo "FAIL raster_check"
exit $fail
