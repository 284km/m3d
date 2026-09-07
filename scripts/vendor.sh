#!/bin/sh
# scripts/vendor.sh — copy the Mere libraries this renderer needs into .mere_modules.
#
# Mere resolves `import "<package>/<module>.mere"` by walking up to the nearest
# .mere_modules/, so a dependency is a vendored copy rather than a path. The copies are
# COMMITTED: a checkout should build without fetching anything first, and the version that
# was built against should be visible in the history rather than implied by whatever
# happened to be on the machine.
#
# Point MERE_SRC at a checkout of the Mere repository.
#
# Usage:  MERE_SRC=/path/to/mere sh scripts/vendor.sh
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -n "${MERE_SRC:-}" ] || { echo "vendor: set MERE_SRC to a checkout of the Mere repository" >&2; exit 1; }
[ -f "$MERE_SRC/contrib/json/json.mere" ] || { echo "vendor: $MERE_SRC does not look like it" >&2; exit 1; }

mkdir -p "$ROOT/.mere_modules/json"
cp "$MERE_SRC/contrib/json/json.mere" "$ROOT/.mere_modules/json/json.mere"
echo "vendored json/json.mere"

# The version matters here and not only for the record: contrib/json could not parse a
# number with a decimal point before v0.1.446, and glTF is unreadable without one.
grep -q 'JFloat' "$ROOT/.mere_modules/json/json.mere" \
  || { echo "vendor: this copy of contrib/json has no JFloat — it predates v0.1.446 and cannot read glTF" >&2; exit 1; }
echo "vendor: ok"
