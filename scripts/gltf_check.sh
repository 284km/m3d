#!/bin/sh
# scripts/gltf_check.sh — four readers on the same glTF files.
#
#   1. THE TWO CONTAINERS AGAINST EACH OTHER. A .gltf with its buffers in files and a .glb
#      with them in a chunk hold the same scene, so the loader must produce identical
#      numbers from both. Needs nothing installed. It is also the weakest of the four and
#      this is measured, not guessed: both containers run the same accessor code, so a
#      reader that ignores `byteStride` misreads every interleaved model and the two
#      containers agree about the misreading perfectly. What is left to it is the
#      container handling.
#
#   2. A SECOND IMPLEMENTATION, exactly. scripts/gltf_oracle.py reads the same file with
#      Python's `struct` and its own GLB walk. Both sides read the same four bytes of a
#      float and divide the same exact integers, so the comparison is BIT-EXACT and a
#      tolerance here would be hiding something. This is the one that catches the stride.
#
#   3. THE KHRONOS VALIDATOR. The two readers above agree with each other and both read
#      the same specification; neither can say whether the FILE is legal glTF. That
#      matters most for the synthetic model, which this repository writes itself: a
#      differential test over a file we invented shows two readers agreeing about bytes we
#      chose, and nothing more.
#
#   4. THE MALFORMED FILES ARE REFUSED, and refused BY NAME. A loader that reads a
#      truncated GLB and returns something is the failure that reaches a picture.
#
# Every count is printed, because a run that compared nothing is not a run that passed.
#
# Usage:  MERE=/path/to/mere.exe sh scripts/gltf_check.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-mere}"
command -v "$MERE" >/dev/null 2>&1 || { echo "gltf_check: no mere — set MERE=..." >&2; exit 1; }
cd "$ROOT"
T="${TMPDIR:-/tmp}/m3d_gltf.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT

fail=0
pairs=0; single=0; oracled=0

# 0. The little-endian reads, against values checked by hand against Python's `struct`.
# Everything below rests on these six functions, so they are asked first and separately:
# a wrong shift would show up as a wrong number a long way from its cause.
le=$("$MERE" test/le_check.mere 2>&1)
case "$le" in
  *"le_check: ok"*) echo "gltf_check: the little-endian reads agree with their pinned values" ;;
  *) echo "gltf_check: le_check failed"; echo "$le" | sed 's/^/    /' | head -5; fail=1 ;;
esac

for d in test/data/gltf/*/; do
  m=$(basename "$d")
  g=$(ls "$d"glTF/*.gltf 2>/dev/null | head -1)
  b=$(ls "$d"glTF-Binary/*.glb 2>/dev/null | head -1)

  if [ -n "$g" ]; then
    if ! "$MERE" test/gltf_dump.mere "$g" > "$T/g.txt" 2>&1; then
      echo "gltf_check: $m .gltf did not load"; sed 's/^/    /' "$T/g.txt" | head -3; fail=1; continue
    fi
  fi
  if [ -n "$b" ]; then
    if ! "$MERE" test/gltf_dump.mere "$b" > "$T/b.txt" 2>&1; then
      echo "gltf_check: $m .glb did not load"; sed 's/^/    /' "$T/b.txt" | head -3; fail=1; continue
    fi
  fi

  # 1. the containers against each other -- their ACCESSOR DATA, not their document.
  #
  # MEASURED: BoxTextured's .glb has four bufferViews and its .gltf has three, because a
  # GLB may carry an image inside the buffer where a .gltf references it as a file beside
  # the document. That is the format working as intended and not a difference in the
  # scene, so the document-shape line is compared per file by the oracle instead, which
  # reads each file's own JSON. The invariant here is narrower than "the same document"
  # and saying which one it is, is the difference between a gate and a wish.
  if [ -n "$g" ] && [ -n "$b" ]; then
    grep -v '^shape ' "$T/g.txt" > "$T/g.acc"; grep -v '^shape ' "$T/b.txt" > "$T/b.acc"
    if diff -q "$T/g.acc" "$T/b.acc" >/dev/null; then
      pairs=$((pairs + 1))
    else
      echo "gltf_check: $m — the two containers disagree about accessor data"
      diff "$T/g.acc" "$T/b.acc" | head -6
      fail=1
    fi
  elif [ -n "$g" ] || [ -n "$b" ]; then
    single=$((single + 1))
  fi

  # 2. the second implementation
  if command -v python3 >/dev/null 2>&1; then
    for f in "$g" "$b"; do
      [ -n "$f" ] || continue
      out=$("$MERE" test/gltf_dump.mere "$f" 2>&1 | python3 scripts/gltf_oracle.py "$f" 2>&1)
      case "$out" in
        *FAIL*) echo "$out" | sed 's/^/  /'; fail=1 ;;
        *) oracled=$((oracled + 1)) ;;
      esac
    done
  fi
done
echo "gltf_check: $pairs model(s) identical across both containers, $single with only one container"
[ "$pairs" -ge 1 ] || { echo "gltf_check: no model had both containers, so check 1 compared nothing"; fail=1; }
if command -v python3 >/dev/null 2>&1; then
  echo "gltf_check: $oracled file(s) agreed with the second implementation, exactly"
  [ "$oracled" -ge 1 ] || { echo "gltf_check: the oracle compared nothing"; fail=1; }
else
  echo "gltf_check: SKIP the second implementation — no python3"
fi

# 3. the outside opinion on whether these are legal glTF
if [ -d node_modules/gltf-validator ] && command -v node >/dev/null 2>&1; then
  files=$(ls test/data/gltf/*/glTF/*.gltf test/data/gltf/*/glTF-Binary/*.glb 2>/dev/null)
  # shellcheck disable=SC2086
  node scripts/validate.js $files || fail=1
else
  echo "gltf_check: SKIP the Khronos validator — run 'npm install gltf-validator'"
fi

# 4. malformed input is refused, by name
python3 - "$T" <<'PY'
import struct, sys, os
T = sys.argv[1]
src = "test/data/gltf/Box/glTF-Binary/Box.glb"
raw = open(src, 'rb').read()
clen, ctype = struct.unpack_from('<II', raw, 12)
cases = {
    # A truncated download is the ordinary way this file arrives broken.
    "truncated.glb":    raw[:len(raw) // 2],
    # A header length that does not match the file.
    "wrong_length.glb": raw[:8] + struct.pack('<I', len(raw) + 4) + raw[12:],
    "bad_magic.glb":    b'glTG' + raw[4:],
    "version_1.glb":    raw[:4] + struct.pack('<I', 1) + raw[8:],
    # chunkLength includes its own padding, so this one is not a glTF.
    "unaligned.glb":    (lambda b: b[:8] + struct.pack('<I', len(b)) + b[12:])(
                            raw[:12] + struct.pack('<II', clen - 1, ctype) + raw[20:]),
}
for name, data in cases.items():
    open(os.path.join(T, name), 'wb').write(data)
print(" ".join(cases))
PY
refused=0; total=0
for c in truncated.glb wrong_length.glb bad_magic.glb version_1.glb unaligned.glb; do
  total=$((total + 1))
  msg=$("$MERE" test/gltf_dump.mere "$T/$c" 2>&1)
  case "$msg" in
    *"glb: "*|*"gltf: "*) refused=$((refused + 1)) ;;
    *) echo "gltf_check: $c was NOT refused with a named reason — got: $(echo "$msg" | head -1)"; fail=1 ;;
  esac
done
echo "gltf_check: $refused of $total malformed files refused by name"

[ "$fail" = 0 ] && echo "PASS gltf_check" || echo "FAIL gltf_check"
exit $fail
