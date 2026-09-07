#!/bin/sh
# scripts/screen_check.sh — the picture on a screen, and the proof that it is the picture.
#
# Every other gate here ends at a buffer. This one puts the buffer in a window, READS THE
# WINDOW'S PIXELS BACK, and compares. Two questions, and they are different:
#
#   1. does the window show what the renderer painted   (readback vs the paint buffer)
#   2. is that the same picture `m3d --out` writes       (readback PNG vs the file PNG)
#
# The second exists because `src/view.mere` and `src/main.mere` are SEPARATE ENTRY POINTS,
# and nothing in question 1 compares them. A window that faithfully shows a frame nobody
# else would have painted passes question 1 and fails the project.
#
# WHY A READBACK IS EVIDENCE HERE AND NORMALLY IS NOT. `Window.show` writes the pixels
# into a block of memory and `Window.capture` reads that same block, so a capture that
# short-circuited would hand back exactly what was written and question 1 would pass
# while proving nothing at all. `contrib/window`'s `capture` fills the block with magenta
# before asking SDL for the pixels, so a readback that does not happen comes back as the
# poison. That poison is in the package, not here; poison P2 below confirms it fires.
#
# POISONED, each one run and its result recorded:
#
#   P1  one byte of the painting changed after it was shown
#         -> FAIL, 1 of 4096 pixels differ, first at (1, 0)      bites
#   P2  `win_readback` replaced by a no-op
#         -> FAIL, 4096 of 4096 differ, window 255,0,255         bites (the package's poison)
#   P3  the composite background changed to red
#         -> ok. A BAD POISON, NOT A HOLE IN THE GATE: `Target.clear` writes alpha 255, so
#            every pixel is opaque, source-over is the identity and NO pixel's colour
#            depends on `bg`. Nothing can detect it because it changes nothing.
#   P4  one pixel left transparent BEFORE the composite
#         -> FAIL, 1 of 4096 differ, window 198,49,49 vs painter 198,23,23. This is the
#            poison that polices the opacity P3 depends on. Placed after `show` first,
#            where it changed only the painter's side of a comparison that reads RGB --
#            it reported ok, and the poison was in the wrong place rather than the gate
#            being blind.
#   P3+P4 together -> FAIL. So the two spellings of the background DO have to agree; it
#            just takes a transparent pixel to make the disagreement visible.
#
# And the gate script itself, four more:
#
#   G1  every model absent          -> red, "this gate is vacuous"
#   G2  the file rendered at 64 px  -> red, every model "not the file's picture". THIS ONE
#         FOUND A DEFECT HERE: vacuity was reported before failures, so a run in which
#         everything failed announced that everything had skipped.
#   G3  the file rendered at t=0.9  -> red for the two animated models only, green for the
#         six that have no animation to be at the wrong time of. So `--time` is plumbed
#         through both entry points and not silently dropped by one.
#   G4  sdl2-config hidden          -> green, and says which piece is missing
#
# WHAT THIS GATE CANNOT SEE. It runs under `SDL_VIDEODRIVER=dummy`, so it exercises
# SDL's software path and not a GPU, a compositor, or a HiDPI scale factor. That is a
# deliberate trade: the dummy driver is the only way the renderer comes back the exact
# size it was asked for, and a comparison between a 256-wide readback and a 128-wide
# painting would report every pixel as differing with the real reason nowhere in the
# output. `src/view.mere` refuses that mismatch by name rather than reporting it as a
# pixel difference. Whether a real display shows this correctly is not checked here.
#
# Usage:  MERE=/path/to/mere.exe sh scripts/screen_check.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-mere}"
command -v "$MERE" >/dev/null 2>&1 || { echo "screen: no mere — set MERE=..." >&2; exit 1; }
CC="${CC:-clang}"
cd "$ROOT"

# SKIP BY NAME, three ways. SDL2 is not a build dependency of a Mere program and the
# window externs are C-backend only, so a machine without either is an ordinary machine.
# Naming which piece is missing is the difference between "this column did not run" and
# a green line that looks like it did.
command -v "$CC" >/dev/null 2>&1 \
  || { echo "screen: SKIP — no $CC, and the window externs are C-backend only"; exit 0; }
command -v sdl2-config >/dev/null 2>&1 \
  || { echo "screen: SKIP — no sdl2-config, so there is no SDL2 to open a window with"; exit 0; }
[ -f "$ROOT/.mere_modules/mere-window/window.mere" ] \
  || { echo "screen: SKIP — mere-window is not vendored — run scripts/vendor.sh"; exit 0; }

T="${TMPDIR:-/tmp}/m3d_screen.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
SDLFLAGS="$(sdl2-config --cflags --libs)"

"$MERE" -c src/view.mere > "$T/view.c" 2>"$T/view.err" \
  || { echo "screen: view.mere did not compile"; head -12 "$T/view.err"; exit 1; }
# shellcheck disable=SC2086
$CC -O2 -w "$T/view.c" -o "$T/view" -lm $SDLFLAGS 2>"$T/view.cc" \
  || { echo "screen: the emitted C did not build against SDL2"; head -12 "$T/view.cc"; exit 1; }
"$MERE" -c src/main.mere > "$T/main.c" 2>"$T/main.err" \
  || { echo "screen: main.mere did not compile"; head -12 "$T/main.err"; exit 1; }
$CC -O2 -w "$T/main.c" -o "$T/m3d" -lm 2>/dev/null \
  || { echo "screen: main.mere's C did not build"; exit 1; }

# A SPREAD, not the whole corpus: the window path does not depend on the model, so the
# list varies what reaches it -- flat colour, a texture, vertex colours, a doubleSided
# plane, a skinned mesh sampled off zero, an animation, a model whose triangles number
# six figures, and a path that is not ASCII. Running all 49 would take minutes to ask the
# same question 49 times. No alpha-blended model is here because none survived the
# corpus's 2 MB cap (test/data/gltf/CORPUS.md), so blending over the window's background
# is NOT covered -- and that is the one case where `show`'s compositing stops being the
# identity, which is exactly what poison P4 stands in for.
MODELS="Box BoxTextured BoxVertexColors TwoSidedPlane Fox AnimatedCube MetalRoughSpheresNoTextures Unicode❤♻Test"
SIZE=128

checked=0; bad=0
for m in $MODELS; do
  f=""
  for cand in "test/data/gltf/$m/glTF/$m.gltf" "test/data/gltf/$m/glTF-Binary/$m.glb"; do
    [ -f "$cand" ] && { f="$cand"; break; }
  done
  [ -n "$f" ] || { printf '%-30s %s\n' "$m" "SKIP — not in the corpus"; continue; }

  msg=$(SDL_VIDEODRIVER=dummy "$T/view" "$f" --size "$SIZE" --time 0.4 --check \
          --out "$T/win.png" 2>&1); rc=$?
  verdict=$(printf '%s\n' "$msg" | grep -o 'm3d-view: [A-Za-z]*' | tail -1)

  # THE WORDS AND THE EXIT CODE MUST AGREE. Checked separately because each covers what
  # the other cannot: a crash before printing leaves no words at all, and a verdict
  # printed on the way out of a path that then returns the wrong code would read as a
  # pass to anything grepping for it.
  case "$verdict:$rc" in
    "m3d-view: ok:0")   ;;
    "m3d-view: SKIP:2") printf '%-30s %s\n' "$m" "$(printf '%s\n' "$msg" | tail -1)"; continue ;;
    "m3d-view: FAIL:1") printf '%-30s %s\n' "$m" "$(printf '%s\n' "$msg" | tail -1)"
                        bad=$((bad + 1)); continue ;;
    *) printf '%-30s %s\n' "$m" "FAIL — said '$verdict' and exited $rc, which do not agree"
       printf '%s\n' "$msg" | head -4 | sed 's/^/    /'
       bad=$((bad + 1)); continue ;;
  esac

  # Question 2. Same size, same time, same animation, so a difference is the entry point.
  "$T/m3d" "$f" --size "$SIZE" --time 0.4 --out "$T/file.png" >/dev/null 2>&1 \
    || { printf '%-30s %s\n' "$m" "FAIL — the window drew it but m3d --out did not"
         bad=$((bad + 1)); continue; }
  if cmp -s "$T/win.png" "$T/file.png"; then
    printf '%-30s %s\n' "$m" "window == painter == file"
    checked=$((checked + 1))
  else
    printf '%-30s %s\n' "$m" "FAIL — the window's picture is not the file's picture"
    bad=$((bad + 1))
  fi
done

# FAILURES ARE REPORTED BEFORE VACUITY, because `checked == 0` has two causes and only
# one of them is "nothing ran". The first version of this checked vacuity first, and
# poisoning the picture comparison made every model fail -- so `checked` was 0 and the
# gate announced "every model skipped, so this gate is vacuous" about a run in which
# nothing skipped and everything failed. Right verdict, wrong reason, and the wrong
# reason is what somebody would go and investigate.
if [ "$bad" -ne 0 ]; then
  echo "screen: $bad model(s) failed, $checked passed"
  exit 1
fi
# CHECKED == 0 IS RED. Every model could SKIP for its own good reason and the loop would
# end with nothing compared and nothing to report, which is not a pass.
if [ "$checked" -eq 0 ]; then
  echo "screen: nothing was compared — every model skipped, so this gate is vacuous"
  exit 1
fi
echo "screen: $checked model(s) shown in a window and read back, identical to the file"
echo "screen: ok"
