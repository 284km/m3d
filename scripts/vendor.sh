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

# PNG, and the DEFLATE it is built on. Two more Mere-written projects rather than a C
# library: MERE_DOGFOOD points at the directory holding them (github.com/284km/<name>).
DOG="${MERE_DOGFOOD:-$(dirname "$(dirname "$MERE_SRC")")/284km}"
# JPEG, which came out of mbrowse into a package of its own when this renderer asked for
# it: six of the corpus's models carry JPEG textures. It reads a JPEG and knows nothing
# about the web, and it now takes BYTES rather than a path -- a glTF image may be a range
# of the binary chunk.
if [ -f "$DOG/mjpeg/jpeg.mere" ]; then
  mkdir -p "$ROOT/.mere_modules/mjpeg"
  cp "$DOG/mjpeg/jpeg.mere" "$ROOT/.mere_modules/mjpeg/jpeg.mere"
  # The version matters: an earlier copy STEPPED PAST a frame marker it did not know, so a
  # progressive JPEG came back as a 0x0 header and said nothing. Two corpus models are
  # progressive, and this renderer needs them refused by name, not silently empty.
  grep -q 'sof_name' "$ROOT/.mere_modules/mjpeg/jpeg.mere" \
    || { echo "vendor: this copy of mjpeg does not refuse unsupported frame types by name" >&2; exit 1; }
  echo "vendored mjpeg/jpeg.mere"
else
  echo "vendor: no mjpeg at $DOG/mjpeg — set MERE_DOGFOOD to the directory holding it" >&2
  exit 1
fi

if [ -f "$DOG/mpng/png.mere" ] && [ -f "$DOG/mgz/inflate.mere" ]; then
  mkdir -p "$ROOT/.mere_modules/mpng" "$ROOT/.mere_modules/mgz"
  cp "$DOG/mpng/png.mere" "$ROOT/.mere_modules/mpng/png.mere"
  cp "$DOG/mpng/encode.mere" "$ROOT/.mere_modules/mpng/encode.mere"
  cp "$DOG/mgz/inflate.mere" "$ROOT/.mere_modules/mgz/inflate.mere"
  cp "$DOG/mgz/deflate.mere" "$ROOT/.mere_modules/mgz/deflate.mere"
  echo "vendored mpng (read and write) and mgz (inflate and deflate)"
else
  echo "vendor: mpng or mgz not found under $DOG — set MERE_DOGFOOD" >&2
  exit 1
fi

echo "vendor: ok"
