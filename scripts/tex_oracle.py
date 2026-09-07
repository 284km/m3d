#!/usr/bin/env python3
"""A second PNG decoder, and a second sampler, on the same files.

A PNG decoder is the one part of this project where a genuinely independent implementation
is available off the shelf, so this uses one: PIL decodes the same files, in another
language, sharing nothing with the Mere reader but the specification. Every texel is
compared EXACTLY -- a decoder is a bit-for-bit question and a tolerance would be hiding
something.

The wrap modes and the sampler are followed here too. Those are a second reading of the
same rules rather than a second implementation, and what they catch is a sign or an
off-by-one -- which is most of what goes wrong in a wrap mode. The bilinear filter has no
rounding to disagree about (three lerps and a table lookup), so it is compared on bit
patterns like everything else.

  mere test/tex_dump.mere | python3 scripts/tex_oracle.py
"""
import math, os, struct, sys, warnings
# Pillow 14 renames getdata; the replacement is not in the version on every machine this
# runs on, so the old call stays and its notice is silenced rather than printed into a
# gate's output, where a warning reads like a finding.
warnings.filterwarnings("ignore", category=DeprecationWarning)
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIR = os.path.join(ROOT, "test", "data", "png")

REPEAT, CLAMP, MIRROR = 10497, 33071, 33648

def srgb_decode_table():
    return [(s / 12.92 if (s := b / 255.0) <= 0.04045 else ((s + 0.055) / 1.055) ** 2.4)
            for b in range(256)]
DEC = srgb_decode_table()

def load(name):
    """RGBA8, with the same channel expansion the reader does. The 16-bit case takes the
    HIGH byte, which is the 8-bit value because PNG samples are big-endian."""
    im = Image.open(os.path.join(DIR, name + ".png"))
    w, h = im.size
    if im.mode == "I;16":
        d = list(im.getdata())
        return w, h, [(v >> 8, v >> 8, v >> 8, 255) for v in d]
    # NO HAND-ROLLED PALETTE PATH. There was one -- look the index up in the palette,
    # alpha 255 -- and it was wrong in the one way that matters: a palette image's
    # transparency is in a tRNS chunk, so "alpha 255" is an assumption and not a
    # reading. It also meant the oracle was re-implementing the palette lookup instead
    # of asking PIL, which is the whole reason for having an oracle. On an image with no
    # tRNS the two agree exactly; on one with a tRNS the hand path says 255 everywhere
    # and PIL says 0, 64, 200, 255.
    return w, h, list(im.convert("RGBA").getdata())

def wrap(mode, i, n):
    if n <= 0: return 0
    if mode == CLAMP: return 0 if i < 0 else (n - 1 if i >= n else i)
    if mode == MIRROR:
        k = ((i % (2 * n)) + 2 * n) % (2 * n)
        return k if k < n else 2 * n - 1 - k
    return ((i % n) + n) % n

def sample(w, h, px, ws, wt, u, v, dec):
    fx = u * w - 0.5
    fy = v * h - 0.5
    x0, y0 = math.floor(fx), math.floor(fy)
    sx, sy = fx - math.floor(fx), fy - math.floor(fy)
    def tx(x, y):
        return px[wrap(wt, y, h) * w + wrap(ws, x, w)]
    c = [tx(x0, y0), tx(x0 + 1, y0), tx(x0, y0 + 1), tx(x0 + 1, y0 + 1)]
    def lerp(a, b, s): return a + (b - a) * s
    def mix(idx, f):
        return lerp(lerp(f(c[0][idx]), f(c[1][idx]), sx), lerp(f(c[2][idx]), f(c[3][idx]), sx), sy)
    lin = lambda b: b / 255.0
    # Alpha is never on a transfer curve; it is a coverage fraction.
    return (mix(0, dec), mix(1, dec), mix(2, dec), mix(3, lin))

def bits(x):
    u = struct.unpack('<Q', struct.pack('<d', float(x)))[0]
    return (u >> 32, u & 0xFFFFFFFF)

def main():
    got, cur = {}, None
    for line in sys.stdin:
        t = line.split()
        if not t: continue
        if t[0] == "image":
            cur = t[1]; got[cur] = {"wh": (int(t[2]), int(t[3])), "t": {}, "w": {}, "s": {}, "l": {}}
        elif cur is None:
            continue
        elif t[0] == "t":
            got[cur]["t"][int(t[1])] = tuple(int(x) for x in t[2:6])
        elif t[0] == "w":
            got[cur]["w"][int(t[1])] = tuple(int(x) for x in t[2:5])
        elif t[0] in ("s", "l"):
            k = int(t[1]); vals = [int(x) for x in t[2:10]]
            got[cur][t[0]][k] = tuple((vals[2 * i], vals[2 * i + 1]) for i in range(4))

    # ITERATE WHAT THE DUMP ACTUALLY PRODUCED, not a list written here.
    #
    # This was a tuple of six names and a message that said "over 6 images" as a
    # literal. Adding two images to test/tex_dump.mere therefore changed nothing at
    # all: the dump grew, the oracle compared the same six, and the line still read
    # "6 images". The two new ones were the tRNS cases -- the whole point of adding
    # them -- and a hand-maintained list is exactly how a gate stops keeping up with
    # what it is pointed at.
    bad, checked = [], 0
    names = sorted(got)
    if not names:
        print("tex_oracle: FAIL -- the dump named no images at all")
        return 1
    for name in names:
        w, h, px = load(name)
        checked += 1
        if got[name]["wh"] != (w, h):
            bad.append(f"{name}: size {got[name]['wh']} vs {(w, h)}"); continue
        for i, p in enumerate(px):
            checked += 1
            if got[name]["t"].get(i) != p:
                bad.append(f"{name} texel {i} ({i % w},{i // w}): mere {got[name]['t'].get(i)} vs PIL {p}")
        for i in range(-10, 11):
            checked += 1
            want = (wrap(REPEAT, i, w), wrap(CLAMP, i, w), wrap(MIRROR, i, w))
            if got[name]["w"].get(i) != want:
                bad.append(f"{name} wrap {i}: mere {got[name]['w'].get(i)} vs {want}")
        for k in range(21):
            u = (k - 4.0) / 12.0
            v = ((20 - k) - 4.0) / 12.0
            for key, ws, wt, dec in (("s", REPEAT, MIRROR, lambda b: DEC[b]),
                                     ("l", MIRROR, REPEAT, lambda b: b / 255.0)):
                checked += 1
                want = tuple(bits(x) for x in sample(w, h, px, ws, wt, u, v, dec))
                if got[name][key].get(k) != want:
                    bad.append(f"{name} {key}[{k}] u={u} v={v}: mere {got[name][key].get(k)} vs oracle {want}")

    if checked < 100:
        print(f"tex_oracle: FAIL -- only {checked} comparisons, which is not a check")
        return 1
    print(f"tex_oracle: {checked} comparisons over {len(names)} images "
          f"({', '.join(names)}), exact, against an independent PNG decoder")
    for b in bad[:8]:
        print("  " + b)
    if bad:
        print(f"tex_oracle: FAIL ({len(bad)} disagree)")
        return 1
    print("tex_oracle: ok")
    return 0

sys.exit(main())
