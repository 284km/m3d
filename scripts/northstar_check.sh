#!/bin/sh
# scripts/northstar_check.sh — every model in the corpus, through the whole thing.
#
# The other gates ask about a layer. This one asks the question the project exists for:
# given a glTF file, does a picture come out. Three columns per model:
#
#   READS   the container, the JSON and every accessor, without a refusal
#   DRAWS   at least one triangle submitted AND pixels changed from the clear colour
#   LIT     the brightest pixel is brighter than ambient alone would be
#
# THE THIRD COLUMN IS THE ONE THAT EARNS ITS PLACE. "Draws" was true of a renderer that
# culled every front face and drew the back ones: a box is still a box from the inside,
# and the only symptom was that the whole model came out one flat ambient colour. A
# silhouette is not evidence that the right triangles were drawn, so the table asks
# separately.
#
# What is NOT here yet is the fourth column -- agreement with a reference renderer.
# three.js reads the same files and the camera this program prints is exactly what it
# needs, so the instrument is ready; what is not ready is the subject, because shading is
# still per vertex and a reference renderer shades per pixel. Comparing them now would
# measure that difference and nothing else. Said here rather than left as a gap.
#
# Usage:  MERE=/path/to/mere.exe sh scripts/northstar_check.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-mere}"
command -v "$MERE" >/dev/null 2>&1 || { echo "northstar: no mere — set MERE=..." >&2; exit 1; }
CC="${CC:-clang}"
command -v "$CC" >/dev/null 2>&1 || { echo "northstar: SKIP — no $CC, and the interpreter is far too slow for this"; exit 0; }
cd "$ROOT"
T="${TMPDIR:-/tmp}/m3d_ns.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT

# COMPILED, and not a preference: the interpreter takes minutes per frame where the C
# backend takes under a second. mbrowse learned the same thing about its own painter.
if ! "$MERE" -c src/main.mere > "$T/m.c" 2> "$T/err"; then
  echo "northstar: src/main.mere did not emit"; sed 's/^/    /' "$T/err" | head -4; exit 1
fi
if ! "$CC" -O2 -w "$T/m.c" -o "$T/m3d" -lm 2>> "$T/err"; then
  echo "northstar: the emitted C did not compile"; grep 'error:' "$T/err" | head -4; exit 1
fi

fail=0; total=0; read_ok=0; drew=0; lit=0; nomesh=0
printf '%-22s %-6s %-6s %-6s %s\n' model reads draws lit note
for d in test/data/gltf/*/; do
  m=$(basename "$d")
  f=$(ls "$d"glTF-Binary/*.glb 2>/dev/null | head -1)
  [ -n "$f" ] || f=$(ls "$d"glTF/*.gltf 2>/dev/null | head -1)
  [ -n "$f" ] || continue
  total=$((total + 1))
  out="$T/$m.png"
  if ! log=$("$T/m3d" "$f" --out "$out" --size 128 2>&1); then
    printf '%-22s %-6s %-6s %-6s %s\n' "$m" no - - "$(echo "$log" | head -1 | cut -c1-46)"
    fail=1; continue
  fi
  read_ok=$((read_ok + 1))
  tri=$(echo "$log" | sed -n 's/^triangles \([0-9]*\).*/\1/p')
  # A file with no mesh at all draws nothing and that is the right answer. Synthetic is
  # an accessor test document: it has bufferViews and nodes and deliberately no geometry,
  # so requiring it to draw would be requiring the corpus to be something it is not.
  if [ "${tri:-0}" = "0" ] && ! grep -q '"mesh"' "$f" 2>/dev/null && ! grep -aq 'mesh' "$f" 2>/dev/null; then
    printf '%-22s %-6s %-6s %-6s %s\n' "$m" yes n/a n/a "no mesh in the document"
    nomesh=$((nomesh + 1)); continue
  fi
  stats=$(python3 - "$out" <<'PY'
import sys, warnings
warnings.filterwarnings("ignore")
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = list(im.getdata())
bg = (26, 26, 30)
hit = [p for p in px if p != bg]
# The brightest channel among drawn pixels. Ambient alone on a mid-grey material lands
# near 100; a lit surface is well above it.
print(len(hit), max((max(p) for p in hit), default=0))
PY
)
  cov=$(echo "$stats" | cut -d' ' -f1)
  bright=$(echo "$stats" | cut -d' ' -f2)
  # PER MODEL, not against a threshold. The same model is rendered again with the
  # directional light black, and "lit" means the light made a difference. A fixed
  # threshold cannot do this: glTF's default material is fully metallic, so its ambient
  # is zero, and 130 either passes a black frame or fails a correct dull metal --
  # SimpleMeshes and Triangle sat exactly there and the column said "no" about a
  # renderer that was working.
  "$T/m3d" "$f" --out "$T/${m}_dark.png" --size 128 --no-light >/dev/null 2>&1
  dark=$(python3 - "$T/${m}_dark.png" <<'PY2'
import sys, warnings
warnings.filterwarnings("ignore")
from PIL import Image
px = list(Image.open(sys.argv[1]).convert("RGB").getdata())
hit = [p for p in px if p != (26, 26, 30)]
print(max((max(p) for p in hit), default=0))
PY2
)
  dcol=no; lcol=no
  [ "${cov:-0}" -gt 20 ] && { dcol=yes; drew=$((drew + 1)); }
  [ "${bright:-0}" -gt "$((${dark:-0} + 8))" ] && { lcol=yes; lit=$((lit + 1)); }
  printf '%-22s %-6s %-6s %-6s %s\n' "$m" yes "$dcol" "$lcol" "$tri tri, $cov px, max $bright vs $dark unlit"
done

echo "northstar: $read_ok of $total read, $drew drew, $lit lit ($nomesh with no geometry)"
# A run that rendered nothing is not a run that passed.
[ "$total" -ge 3 ] || { echo "northstar: only $total model(s) in the corpus, which is not a check"; fail=1; }
[ "$drew" = "$((read_ok - nomesh))" ] || { echo "northstar: $((read_ok - nomesh - drew)) model(s) with geometry read but drew nothing"; fail=1; }
[ "$lit" = "$drew" ] || { echo "northstar: $((drew - lit)) model(s) drew but came out no brighter than ambient"; fail=1; }

[ "$fail" = 0 ] && echo "PASS northstar" || echo "FAIL northstar"
exit $fail
