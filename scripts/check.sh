#!/bin/sh
# scripts/check.sh — everything this repository can be held to, so far.
#
# Needs a built `mere` on PATH, or MERE pointing at one. Set MERE_SRC to a
# checkout of the Mere repository to include the Wasm backend (it needs that
# repository's Node host); without it the Wasm column is SKIPPED and says so.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-mere}"
command -v "$MERE" >/dev/null 2>&1 || { echo "check: no mere — set MERE=/path/to/mere.exe" >&2; exit 1; }
export MERE
sh "$ROOT/scripts/linalg_check.sh" || exit 1
sh "$ROOT/scripts/gltf_check.sh" || exit 1
sh "$ROOT/scripts/raster_check.sh" || exit 1
sh "$ROOT/scripts/shade_check.sh" || exit 1

out=$("$MERE" "$ROOT/test/render_props.mere" 2>&1) || { echo "check: render_props did not run"; echo "$out" | head -3; exit 1; }
case "$out" in
  *"render_props: ok"*) echo "check: the pipeline properties hold (the winding, above all)" ;;
  *) echo "$out" | grep MISMATCH | head -6; echo "check: a pipeline property failed"; exit 1 ;;
esac

sh "$ROOT/scripts/northstar_check.sh" || exit 1

# The one gate that compares this renderer against something other than itself. It
# SKIPS ITSELF when the reference is not installed -- Chrome, Pillow and three.js are
# not build dependencies of a Mere program -- and says which piece is missing, so a
# green run is not evidence that this column ran. Its own line reports how many models
# it compared.
sh "$ROOT/scripts/reference_check.sh" || exit 1

# The only gate that ends at a screen instead of a buffer: it opens a window, shows a
# frame, READS THE WINDOW'S PIXELS BACK and compares. SKIPS ITSELF, by name, without SDL2
# or a C compiler -- neither is a build dependency of a Mere program, and the window
# externs are C-backend only.
sh "$ROOT/scripts/screen_check.sh" || exit 1

# What a frame costs, and whether the loop grows. One assertion (peak RSS does not
# scale with the frame count) and one report (frame times at two sizes, unpinned --
# machine load moves them by a factor of two). SKIPS by name without SDL2, a C
# compiler, or a /usr/bin/time that reports peak RSS in a spelling it knows.
sh "$ROOT/scripts/bench_check.sh" || exit 1
echo "check: ok"
