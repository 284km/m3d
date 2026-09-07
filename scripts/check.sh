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
sh "$ROOT/scripts/linalg_check.sh"
echo "check: ok"
