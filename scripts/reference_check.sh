#!/bin/sh
# scripts/reference_check.sh — the fourth column: does it agree with another renderer.
#
# The other gates compare this project against itself, against a second reading of the
# same specification, or against exact arithmetic. This one points three.js at the SAME
# glTF file and compares the pictures.
#
# IT IS HANDED THE CAMERA RATHER THAN ASKED TO GUESS IT. Most sample models carry no
# camera, so a viewer invents one from the scene's bounds, and two viewers will not invent
# the same one. m3d prints the camera it computed -- as the TANGENT of the half angle, so
# not even a `tan` sits between the two -- and the reference is given those numbers.
# Otherwise this would be a measurement of two framing heuristics.
#
# Each model is rendered by the reference TWICE:
#
#   STOCK three.js, which diverges from glTF's normative appendix in three ways m3d
#   deliberately does not follow -- it compensates for multiple scattering in the direct
#   specular term, it omits the (1 - F) in front of the diffuse lobe, and it interpolates
#   F0 toward the base colour instead of mixing two BRDFs. So this number is RECORDED,
#   pinned per model, and not thresholded against anything anyone invented.
#
#   three.js PATCHED to the appendix on the first two of those (?gltfbrdf=1), which is
#   where the strong claim is: on a model that uses nothing m3d is missing, the two
#   renderers agree BYTE FOR BYTE, and that pin is held at exactly 0.
#
# The silhouette is gated in both a pinned and an absolute way. Same geometry, same
# camera, so which pixels are covered has one answer, and this is the column that catches
# a wrong matrix, a dropped node, a flipped winding or a mis-read accessor.
#
# WHAT IT FOUND. The renderer had a complete, tested texture module that nothing called:
# `Tex` was built and had its own oracle, and `render.mere` sampled it nowhere. Every
# other gate passed, because the silhouette was right and the lighting was right and the
# duck was simply white. Nothing that compares this renderer against itself can see that.
#
# WHAT IT WAS SHOWN TO CATCH. Six poisons, each reverted:
#
#   * A NODE TRANSFORM IGNORED (`local` stops reading `matrix`). Duck's root node is a
#     uniform scale of 0.01, so ignoring it makes the duck a hundred times bigger -- AND
#     THE AUTO-CAMERA GROWS WITH IT, to the pixel. m3d's own picture is byte-identical
#     under this bug; only a renderer handed that hundred-times camera while drawing the
#     correctly scaled duck can see it, and it comes out as IoU 0.000. That is the class
#     of defect this column exists for: anything the framing heuristic absorbs is
#     invisible to a renderer that frames its own output.
#   * THE BASE COLOUR TEXTURE SAMPLED AND THEN DISCARDED (the bug this gate found).
#     Caught on all three textured models, in both colour columns.
#   * THE (1 - F) glTF PUTS in front of the diffuse lobe, DROPPED. Caught on all five
#     dielectrics by the patched column -- AND THE STOCK COLUMN GOT BETTER, from 1.0 to
#     0.1 on Box. Stock three.js has the same omission, so a gate pinned only against it
#     would have rewarded the spec violation. That is why the patched column is here and
#     not just the honest one.
#   * THE PAGE NOT PAINTING ITS FINISHED-RENDER STRIP, and THE SHADER PATCH NO LONGER
#     MATCHING (which makes the page throw before painting the strip). Both refused by
#     name. Neither can quietly become a measurement of the unpatched renderer.
#   * THE CAMERA MARGIN moved from 1.15 to 1.35. Caught ONLY by Triangle's exact-zero
#     pin, at 0.04% of pixels -- see the blind spot below.
#
# WHAT IT IS BLIND TO. THE FRAMING HEURISTIC. m3d computes the camera and the reference is
# given it, so a change to how models are framed moves both pictures together and the IoU
# and colour columns cannot see it at all. That is deliberate -- the alternative is
# measuring two framing heuristics against each other -- and it is northstar_check's
# question, not this one's. The one thread of evidence here is the byte-exact pin, which
# breaks on any perturbation whatsoever, including one both renderers see.
#
# Usage:  MERE=/path/to/mere.exe sh scripts/reference_check.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-mere}"
CC="${CC:-clang}"
SIZE="${SIZE:-192}"
PORT="${PORT:-8731}"
cd "$ROOT"

CHROME="${CHROME:-}"
if [ -z "$CHROME" ]; then
  # Any headless Chrome will do. The Playwright cache is looked in by glob rather than
  # by revision, because that number changes with every Playwright release and a hard
  # one would silently turn this gate into a SKIP.
  for c in "$HOME"/Library/Caches/ms-playwright/chromium*/chrome-mac*/*.app/Contents/MacOS/* \
           "$HOME"/.cache/ms-playwright/chromium*/chrome-linux/chrome \
           "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
           "$(command -v google-chrome 2>/dev/null)" "$(command -v chromium 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && CHROME="$c" && break
  done
fi
[ -n "$CHROME" ] || { echo "reference_check: SKIP — no Chrome (set CHROME=...)"; exit 0; }
[ -f "$ROOT/scripts/ref/three.module.js" ] || { echo "reference_check: SKIP — run scripts/ref_setup.sh"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "reference_check: SKIP — no python3"; exit 0; }
command -v "$CC" >/dev/null 2>&1 || { echo "reference_check: SKIP — no $CC"; exit 0; }
python3 -c 'import PIL' 2>/dev/null || { echo "reference_check: SKIP — no Pillow"; exit 0; }

T="${TMPDIR:-/tmp}/m3d_ref.$$"; mkdir -p "$T"
srv=""
cleanup() { [ -n "$srv" ] && kill "$srv" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT INT TERM

"$MERE" -c src/main.mere > "$T/m.c" 2>"$T/e" && "$CC" -O2 -w "$T/m.c" -o "$T/m3d" -lm 2>>"$T/e" \
  || { echo "reference_check: m3d did not build"; head -5 "$T/e"; exit 1; }

# A module script cannot be loaded from file:// -- the browser refuses it as
# cross-origin -- so the tree is served, rooted at the repository so a model's own
# buffers and images resolve by their relative uris exactly as they do on disk.
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$ROOT" >/dev/null 2>&1 &
srv=$!
i=0
while [ "$i" -lt 40 ]; do
  python3 - "$PORT" <<'PY' && break
import socket, sys
s = socket.socket()
s.settimeout(0.2)
sys.exit(s.connect_ex(("127.0.0.1", int(sys.argv[1]))))
PY
  i=$((i + 1))
done
[ "$i" -lt 40 ] || { echo "reference_check: the local server never came up on port $PORT"; exit 1; }

# The viewport is four pixels taller than the picture: the page paints that strip only
# after three.js returns from render(), and compare.py refuses any frame without it. See
# the note in page.html -- a screenshot of a half-loaded page is a valid PNG of the right
# size in the right background colour, and it silently answers a different question.
#
# The strip is checked HERE TOO, and a frame without one is RETAKEN. Headless Chrome
# occasionally screenshots before the compositor has drawn, and that is the browser
# rather than anything under test. Retrying is fine; retrying quietly is not, so each
# retake prints. A run that never gets a finished frame fails and names the model.
#
# THE BUDGET ESCALATES ACROSS ATTEMPTS -- 20 s, then 60, then 120 -- and it used to be
# a flat 20 s for all four. Both halves of that were measured.
#
# 20 s ALONE IS TOO SHORT FOR AT LEAST ONE MODEL. This comment used to say the misses
# were "on no particular model and not reproducibly"; `NormalTangentTest` then failed on
# two consecutive runs, and by hand each of its three variants misses at 20 s and
# finishes at 90 s. Four retries against a deterministic wall are four identical
# failures, which is why retrying never helped and why the gate said "never produced a
# finished frame" about a page that simply needed longer.
#
# A LARGER BUDGET IS FREE WHEN THE PAGE FINISHES AND COSTS THE WHOLE OF IT WHEN IT DOES
# NOT. The budget is a CAP on virtual time rather than a wait, so Chrome exits as soon as
# the page goes idle: `Box` takes 1.14 s at 20 s and 1.10-1.16 s at 120 s, timed three
# times each. But a frame that never finishes burns the full budget, and then the retry
# loop multiplies it -- a flat 120 s meant 8 minutes on one frame that was never going
# to work. Escalating keeps the common case at 20 s, clears an ordinary one-off flake
# cheaply on the second attempt, and reaches 120 s only for a page that has already
# missed twice.
#
# WHAT THIS STILL DOES NOT FIX, so that a future reader does not mistake it for solved:
# under heavy machine load `NormalTangentTest` has missed all four attempts even at
# 120 s. The gate then refuses to report a number and names the model, which is the
# right behaviour, but it means a red line here can still be the machine rather than the
# renderer. Check the load before believing it.
#
# The first green run under the escalation printed exactly the shape this predicts:
# `NormalTangentMirrorTest.patched` missed at 20 s and finished at 60; `.nomip` of
# NormalTangentTest missed 20 and 60 and finished at 120; and its `.stock` missed all
# of 20, 60 and 120 and finished on the fourth attempt. So both things are real at
# once -- a budget that was too short, AND ordinary flake on top of it -- which is why
# the retries stay and why they print what they were given.
shoot() { # url out
  k=0
  for budget in 20000 60000 120000 120000; do
    rm -f "$2"
    "$CHROME" --headless --no-sandbox --disable-gpu --use-angle=swiftshader \
      --enable-unsafe-swiftshader --hide-scrollbars --force-device-scale-factor=1 \
      --run-all-compositor-stages-before-draw \
      --window-size="$SIZE,$((SIZE + 4))" --virtual-time-budget="$budget" \
      --screenshot="$2" "$1" >/dev/null 2>&1
    if [ -s "$2" ] && python3 scripts/ref/finished.py "$2" "$SIZE"; then return 0; fi
    k=$((k + 1))
    # THE BUDGET IS PRINTED, because "retaking" four times says nothing about whether
    # the page is flaky or simply slow, and those want different fixes.
    echo "  (retaking $(basename "$2") at ${budget}ms: the browser screenshotted before three.js drew)"
  done
  return 1
}

# The pins in scripts/ref/pinned.txt are numbers at one size; at another size every model
# would be unpinned, which this gate treats as a failure. Rather than let that read as a
# broken gate, a non-default size is refused up front and by name.
[ "$SIZE" = 192 ] || { echo "reference_check: pins are for 192x192; SIZE=$SIZE can only be a diagnostic run"; exit 1; }

fail=0
compared=0
printf '%-30s %-7s %-8s %-10s %-9s %-7s %s\n' model IoU 'MAE vs' 'MAE vs' 'MAE +no' 'px'   ''
printf '%-30s %-7s %-8s %-10s %-9s %-7s %s\n' ''    ''    'stock'  'glTF BRDF' 'minify' 'diff%' ''
for d in test/data/gltf/*/; do
  m=$(basename "$d")
  f=$(ls "$d"glTF/*.gltf 2>/dev/null | head -1)
  [ -n "$f" ] || continue
  # A BACKGROUND NO SURFACE LANDS ON. "Covered" has to be decidable from the
  # picture, and against the default dark grey a dark surface is background --
  # Suzanne read 0.92 on a silhouette measure with nothing wrong with its
  # geometry, and adding a texture slot MOVED that number, which is how a
  # silhouette measure tells you it is answering a colour question. Magenta is
  # not a proof (a magenta emissive surface would still fool it); the exact
  # answer is two renders on two backgrounds, which is not paid for yet.
  log=$("$T/m3d" "$f" --out "$T/$m.mine.png" --size "$SIZE" --bg 255,0,255 2>&1) || {
    echo "$m: m3d refused it — $(echo "$log" | tail -1)"; continue; }
  tri=$(echo "$log" | sed -n 's/^primitives \([0-9]*\).*/\1/p')
  [ "${tri:-0}" -gt 0 ] || { echo "$m: nothing drawn, so there is nothing to compare"; continue; }
  set -- $(echo "$log" | sed -n 's/^camera eye \([^ ]*\) \([^ ]*\) \([^ ]*\) target \([^ ]*\) \([^ ]*\) \([^ ]*\) tan_half_yfov \([^ ]*\) znear \([^ ]*\) zfar \([^ ]*\)$/\1 \2 \3 \4 \5 \6 \7 \8 \9/p')
  [ $# -eq 9 ] || { echo "$m: FAIL — could not read the camera back out of m3d"; fail=1; continue; }
  url="http://127.0.0.1:$PORT/scripts/ref/page.html?file=/$f&size=$SIZE&ex=$1&ey=$2&ez=$3&tx=$4&ty=$5&tz=$6&th=$7&zn=$8&zf=$9"
  shoot "$url" "$T/$m.stock.png" || { echo "$m: FAIL — stock three.js never produced a finished frame"; fail=1; continue; }
  shoot "$url&gltfbrdf=1" "$T/$m.patched.png" || { echo "$m: FAIL — three.js patched to glTF's BRDF never produced a finished frame"; fail=1; continue; }
  # A THIRD FRAME, WITH MINIFICATION OFF, for models that have a texture at all.
  #
  # three.js builds a mipmap chain and samples it trilinearly; m3d has none and
  # samples the full-resolution image. That difference is the largest colour
  # residual in the table and it CANNOT BE MATCHED EXACTLY -- `gl.generateMipmap`'s
  # filter is implementation-defined, the level of detail comes from screen-space
  # derivatives, and the implementation here is a software GL driver rather than a
  # document anyone can follow. Matching libjpeg's integer IDCT was possible because
  # libjpeg IS a document; matching swiftshader's mipmap chain is not.
  #
  # So the reference is asked to stop doing it, and the resulting number is what
  # measures THE SAMPLING M3D ACTUALLY IMPLEMENTS. Whether to build mipmaps is then
  # a question about picture quality, not about agreement.
  #
  # Passed only where the document mentions images, because the page treats "the
  # switch found no textures" as fatal -- a switch that silently touched nothing
  # would make the number look like an answer about mipmaps when it is an answer
  # about a model with none.
  if grep -q '"images"' "$f" 2>/dev/null; then
    shoot "$url&gltfbrdf=1&nomip=1" "$T/$m.nomip.png" \
      || { echo "$m: FAIL — three.js with minification off never produced a finished frame"; fail=1; continue; }
    nomip="$T/$m.nomip.png"
  else
    # No textures, so there is nothing to minify and the two frames are the same
    # question. Saying so beats inventing a third number.
    nomip="$T/$m.patched.png"
  fi
  python3 scripts/ref/compare.py "$m" "$T/$m.mine.png" "$T/$m.stock.png" "$T/$m.patched.png" "$nomip" || fail=1
  compared=$((compared + 1))
done

echo "reference_check: $compared model(s) compared against three.js at ${SIZE}x${SIZE}"
# A gate that checked nothing is red. This one has been green with every IoU at 0.000,
# because a table of unpinned models had nothing to disagree with.
[ "$compared" -ge 8 ] || { echo "reference_check: only $compared compared, which is not a check"; fail=1; }
[ "$fail" = 0 ] && echo "PASS reference_check" || echo "FAIL reference_check"
exit $fail
