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
# The fourth column -- agreement with a reference renderer -- is `reference_check.sh`, and
# it is a separate gate rather than a fourth column here because it needs Chrome and
# three.js and this one needs nothing but a C compiler. The two are not interchangeable:
# THIS gate owns the framing heuristic, which that one is deliberately blind to (it is
# handed the camera), and that one owns everything the auto-camera absorbs, which this
# one cannot see (ignore every node matrix and Duck's picture is byte-identical, because
# the camera scales with the bug).
#
# What this gate does NOT do is pin its numbers. `max 232 vs 108 unlit` is a report, not
# an assertion, so wiring base-colour textures into the renderer moved every textured
# model's brightness and this table said nothing. The pins live in
# scripts/ref/pinned.txt instead. Recorded here rather than left to be assumed.
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

# MODELS THIS LOADER CANNOT READ, AND WHY -- listed, not tolerated.
#
# The gate holds the list EXACTLY: a refusal that is not on it fails, and a model on it
# that has started reading ALSO fails. The second half is the one that matters -- a list
# of known failures with no way to notice that one is fixed becomes a list nobody looks
# at -- and it has already earned its keep: the list was six models with JPEG textures,
# and when the mjpeg package landed FOUR OF THEM STARTED READING and this line is what
# made the gate say so rather than keep passing.
#
# The two that remain are PROGRESSIVE JPEGs, which is a different and much larger feature
# than baseline: spectral selection and successive approximation, several scans per
# component. The refusal names it, which is the point -- it used to say "not a PNG".
KNOWN_REFUSALS="CesiumMan CesiumMilkTruck"
KNOWN_REASON="a progressive JPEG, and mjpeg reads baseline and extended sequential only"

fail=0; total=0; read_ok=0; drew=0; lit=0; nomesh=0
refused=""
printf '%-22s %-6s %-6s %-6s %s\n' model reads draws lit note
for d in test/data/gltf/*/; do
  m=$(basename "$d")
  f=$(ls "$d"glTF-Binary/*.glb 2>/dev/null | head -1)
  [ -n "$f" ] || f=$(ls "$d"glTF/*.gltf 2>/dev/null | head -1)
  [ -n "$f" ] || continue
  total=$((total + 1))
  out="$T/$m.png"
  if ! log=$("$T/m3d" "$f" --out "$out" --size 128 2>&1); then
    why=$(echo "$log" | head -1 | cut -c1-46)
    case " $KNOWN_REFUSALS " in
      *" $m "*)
        printf '%-22s %-6s %-6s %-6s %s\n' "$m" "no*" - - "$why"
        refused="$refused $m" ;;
      *)
        printf '%-22s %-6s %-6s %-6s %s\n' "$m" no - - "$why"
        fail=1 ;;
    esac
    continue
  fi
  # A model on the known-refusal list that now reads is not good news the gate may
  # swallow: the list is wrong and has to be edited.
  case " $KNOWN_REFUSALS " in
    *" $m "*)
      echo "northstar: $m is on the known-refusal list and now READS — take it off the list"
      fail=1 ;;
  esac
  read_ok=$((read_ok + 1))
  tri=$(echo "$log" | sed -n 's/^triangles \([0-9]*\).*/\1/p')
  # A file with no mesh at all draws nothing and that is the right answer. Synthetic is
  # an accessor test document: it has bufferViews and nodes and deliberately no geometry,
  # so requiring it to draw would be requiring the corpus to be something it is not.
  if [ "${tri:-0}" = "0" ] && ! grep -q '"mesh"' "$f" 2>/dev/null && ! grep -aq 'mesh' "$f" 2>/dev/null; then
    printf '%-22s %-6s %-6s %-6s %s\n' "$m" yes n/a n/a "no mesh in the document"
    nomesh=$((nomesh + 1)); continue
  fi
  # PER MODEL, not against a threshold. The same model is rendered again with the
  # directional light black, and "lit" means the light made a difference. A fixed
  # threshold cannot do this: glTF's default material is fully metallic, so its ambient
  # is zero, and 130 either passes a black frame or fails a correct dull metal --
  # SimpleMeshes and Triangle sat exactly there and the column said "no" about a
  # renderer that was working.
  #
  # AND IT COUNTS PIXELS THAT CHANGED, NOT THE BRIGHTEST ONE. Comparing maxima is what
  # this did, and it CANNOT SEE A LIGHT ON A BRIGHT SURFACE: three models have textures
  # bright enough that ambient alone already saturates their brightest pixel, so
  # `max 255 vs 255 unlit` read as "the light did nothing" about a renderer that was
  # working -- the same failure as the fixed threshold, one level up. How many pixels
  # got brighter cannot saturate away.
  "$T/m3d" "$f" --out "$T/${m}_dark.png" --size 128 --no-light >/dev/null 2>&1
  stats=$(python3 - "$out" "$T/${m}_dark.png" <<'PY'
import sys, warnings
warnings.filterwarnings("ignore")
from PIL import Image
BG = (26, 26, 30)
lit = list(Image.open(sys.argv[1]).convert("RGB").getdata())
dark = list(Image.open(sys.argv[2]).convert("RGB").getdata())
hit = [(a, b) for a, b in zip(lit, dark) if a != BG or b != BG]
brighter = sum(1 for a, b in hit if max(a) > max(b))
print(len(hit), brighter, max((max(a) for a, _ in hit), default=0),
      max((max(b) for _, b in hit), default=0))
PY
)
  cov=$(echo "$stats" | cut -d' ' -f1)
  brighter=$(echo "$stats" | cut -d' ' -f2)
  bright=$(echo "$stats" | cut -d' ' -f3)
  dark=$(echo "$stats" | cut -d' ' -f4)
  dcol=no; lcol=no
  [ "${cov:-0}" -gt 20 ] && { dcol=yes; drew=$((drew + 1)); }
  # ANY pixel getting brighter, and the count is printed so a weak response is visible
  # rather than hidden. Not a fraction: a fraction is a number somebody invents, and
  # this renderer is deterministic, so there is no noise for a floor to sit above. The
  # bug this column exists for -- every front face culled, the whole model one flat
  # ambient colour -- produces EXACTLY ZERO, which is what is being tested.
  #
  # A fifth of the covered pixels was the first threshold here and it failed
  # TextureLinearInterpolationTest, whose swatches are mostly EMISSIVE: they emit their
  # own light and a directional one cannot brighten them, so 58 of 2101 pixels
  # responding is the right answer about a correct renderer. Tuning the fraction until
  # that model passed would have been fitting the threshold to the answer.
  [ "${brighter:-0}" -gt 0 ] && { lcol=yes; lit=$((lit + 1)); }
  printf '%-22s %-6s %-6s %-6s %s\n' "$m" yes "$dcol" "$lcol" \
    "$tri tri, $cov px, $brighter brighter, max $bright vs $dark unlit"
done

nref=0
for m in $refused; do nref=$((nref + 1)); done
nknown=0
for m in $KNOWN_REFUSALS; do nknown=$((nknown + 1)); done
echo "northstar: $read_ok of $total read, $drew drew, $lit lit ($nomesh with no geometry)"
if [ "$nref" -gt 0 ]; then
  echo "northstar: $nref refused* — each one $KNOWN_REASON"
fi
[ "$nref" = "$nknown" ] || {
  echo "northstar: $nknown model(s) are on the known-refusal list but $nref were refused"
  fail=1; }
# A run that rendered nothing is not a run that passed.
[ "$total" -ge 3 ] || { echo "northstar: only $total model(s) in the corpus, which is not a check"; fail=1; }
[ "$drew" = "$((read_ok - nomesh))" ] || { echo "northstar: $((read_ok - nomesh - drew)) model(s) with geometry read but drew nothing"; fail=1; }
[ "$lit" = "$drew" ] || { echo "northstar: $((drew - lit)) model(s) drew but came out no brighter than ambient"; fail=1; }

[ "$fail" = 0 ] && echo "PASS northstar" || echo "FAIL northstar"
exit $fail
