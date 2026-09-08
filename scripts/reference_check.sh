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
. "$ROOT/scripts/ccflags.sh"
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

# shellcheck disable=SC2086
"$MERE" -c src/main.mere > "$T/m.c" 2>"$T/e" && "$CC" $CFLAGS_M3D "$T/m.c" -o "$T/m3d" -lm 2>>"$T/e" \
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
# THE LOAD, READ RATHER THAN ASKED ABOUT. A page that does not finish in 120 s of
# virtual time is usually a busy machine, and this gate used to end that sentence with
# "check the load before believing it" -- an instruction to a human for a number the
# script can read. It is reported at the start, at every retake and at every failure, so
# a red line carries its own attribution instead of needing a re-run to get one.
cores=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 1)
load1() {
  if [ -r /proc/loadavg ]; then cut -d' ' -f1 /proc/loadavg
  else sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1}'
  fi
}
loadnote() {
  l=$(load1)
  [ -n "$l" ] || { echo ""; return; }
  awk -v l="$l" -v c="$cores" 'BEGIN{printf " [load %.2f over %d core(s) = %.2f per core]", l, c, l/c}'
}

[ "$i" -lt 40 ] || { echo "reference_check: the local server never came up on port $PORT"; exit 1; }
echo "reference_check: starting$(loadnote)"

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
# READING THE CANVAS INSTEAD WAS TRIED, AND IT IS WORSE. page.html renders with
# `preserveDrawingBuffer` and can hand out `canvas.toDataURL()` one statement after
# `render()`, which removes the compositor from the path entirely -- measured on Box,
# the two agree on all 36,864 pixels. But getting it out needs `--dump-dom`, and
# **`--dump-dom` does not wait the way `--screenshot` does**: on Suzanne, three runs in
# a row at the same load gave `<title>LOADING</title>` twice -- dumped before the loader
# had even called back -- where the screenshot of the same page was finished every time.
# So the capture that races less is behind a trigger that fires earlier, and the
# screenshot stays. Written down so the next reader does not spend the same afternoon.
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
# A RED LINE CAN STILL BE THE MACHINE, and the gate now says so itself instead of
# asking the reader to check. The load average is read at the start and again at every
# retake and every failure, so the report carries the one number needed to attribute it
# -- "check the load before believing it" is not an instruction a gate should be handing
# out when it can read the load.
#
# What the escalation printed on its first green run was exactly the shape this
# predicts: `NormalTangentMirrorTest.patched` missed at 20 s and finished at 60;
# `.nomip` of NormalTangentTest missed 20 and 60 and finished at 120; and its `.stock`
# missed all three budgets and finished on the fourth attempt. So both things are real
# at once -- a budget that was too short, AND ordinary flake on top of it -- which is
# why the retries stay and why they print what they were given, now with the load.
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
    # THE BUDGET AND THE LOAD ARE PRINTED, because "retaking" four times says nothing
    # about whether the page is flaky, simply slow, or waiting behind other work -- and
    # those want different fixes.
    echo "  (retaking $(basename "$2") at ${budget}ms: the browser screenshotted before three.js drew$(loadnote))"
  done
  return 1
}

# The pins in scripts/ref/pinned.txt are numbers at one size; at another size every model
# would be unpinned, which this gate treats as a failure. Rather than let that read as a
# broken gate, a non-default size is refused up front and by name.
[ "$SIZE" = 192 ] || { echo "reference_check: pins are for 192x192; SIZE=$SIZE can only be a diagnostic run"; exit 1; }

fail=0
compared=0
# The worst load seen while something was failing. A single number at the end is what
# turns "20 models are red" into "20 models are red and the machine was at 15 per core",
# which are different reports and want different actions.
peak_fail_load=0
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
  shoot "$url" "$T/$m.stock.png" || { echo "$m: FAIL — stock three.js never produced a finished frame$(loadnote)"; peak_fail_load=$(awk -v a="$peak_fail_load" -v b="$(load1)" -v c="$cores" 'BEGIN{b=b/c; print (b>a)?b:a}'); fail=1; continue; }
  shoot "$url&gltfbrdf=1" "$T/$m.patched.png" || { echo "$m: FAIL — three.js patched to glTF's BRDF never produced a finished frame$(loadnote)"; peak_fail_load=$(awk -v a="$peak_fail_load" -v b="$(load1)" -v c="$cores" 'BEGIN{b=b/c; print (b>a)?b:a}'); fail=1; continue; }
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
      || { echo "$m: FAIL — three.js with minification off never produced a finished frame$(loadnote)"; peak_fail_load=$(awk -v a="$peak_fail_load" -v b="$(load1)" -v c="$cores" 'BEGIN{b=b/c; print (b>a)?b:a}'); fail=1; continue; }
    nomip="$T/$m.nomip.png"
  else
    # No textures, so there is nothing to minify and the two frames are the same
    # question. Saying so beats inventing a third number.
    nomip="$T/$m.patched.png"
  fi
  python3 scripts/ref/compare.py "$m" "$T/$m.mine.png" "$T/$m.stock.png" "$T/$m.patched.png" "$nomip" || fail=1
  compared=$((compared + 1))
done

# THE CAMERA INSIDE THE GEOMETRY, which the corpus never asks for.
#
# Every model above is framed from OUTSIDE, so none of them crosses the near plane and
# none could have noticed that a triangle with a vertex behind it was dropped whole.
# With the eye inside `Box`, three.js filled all 36,864 pixels and this renderer drew
# ZERO -- a hole the whole corpus was blind to, which is why this row exists: a feature
# nobody's input exercises has no witness at all.
#
# The camera is the `--orbit` one zoomed past the surface, which is the path the window
# drives, and three.js is handed the same numbers as every row above. Both sides must
# FILL the frame, not merely agree -- two renderers that both drew nothing would agree
# perfectly.
BOXF="test/data/gltf/Box/glTF/Box.gltf"
if [ -f "$BOXF" ]; then
  ilog=$("$T/m3d" "$BOXF" --out "$T/inside.mine.png" --size "$SIZE" --bg 255,0,255 --orbit 30,20,0.3 2>&1)
  set -- $(echo "$ilog" | sed -n 's/^camera eye \([^ ]*\) \([^ ]*\) \([^ ]*\) target \([^ ]*\) \([^ ]*\) \([^ ]*\) tan_half_yfov \([^ ]*\) znear \([^ ]*\) zfar \([^ ]*\)$/\1 \2 \3 \4 \5 \6 \7 \8 \9/p')
  if [ $# -ne 9 ]; then
    echo "near-plane: FAIL - could not read the camera back out of m3d for the inside view"; fail=1
  else
    iurl="http://127.0.0.1:$PORT/scripts/ref/page.html?file=/$BOXF&size=$SIZE&ex=$1&ey=$2&ez=$3&tx=$4&ty=$5&tz=$6&th=$7&zn=$8&zf=$9"
    if ! shoot "$iurl" "$T/inside.ref.png"; then
      echo "near-plane: FAIL - three.js never produced a finished frame for the inside view$(loadnote)"; fail=1
    else
      python3 scripts/ref/inside.py "$T/inside.mine.png" "$T/inside.ref.png" "$SIZE" || fail=1
    fi
  fi
else
  echo "near-plane: SKIP - $BOXF is not here"
fi

echo "reference_check: $compared model(s) compared against three.js at ${SIZE}x${SIZE}"
# A gate that checked nothing is red. This one has been green with every IoU at 0.000,
# because a table of unpinned models had nothing to disagree with.
[ "$compared" -ge 8 ] || { echo "reference_check: only $compared compared, which is not a check"; fail=1; }
if [ "$fail" != 0 ]; then
  # ATTRIBUTION, NOT AN EXCUSE. The gate still fails -- it could not report a number --
  # but a reader should not have to re-run it to find out whether the renderer or the
  # machine was at fault, and this is the measurement that says which. One core's worth
  # of load per core is a busy machine, and the frames that miss here miss under
  # contention.
  busy=$(awk -v l="$peak_fail_load" 'BEGIN{print (l > 1.0) ? 1 : 0}')
  if [ "$busy" = 1 ]; then
    echo "reference_check: the failures above happened with the machine at $(awk -v l="$peak_fail_load" 'BEGIN{printf "%.2f", l}') per core."
    echo "reference_check: that is the usual cause of an unfinished frame here. Re-run on an idle machine before reading this as a renderer change."
  fi
fi
[ "$fail" = 0 ] && echo "PASS reference_check" || echo "FAIL reference_check"
exit $fail
