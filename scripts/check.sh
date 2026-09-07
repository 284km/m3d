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
echo "check: ok"
