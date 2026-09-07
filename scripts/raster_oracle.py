#!/usr/bin/env python3
"""Decides the same coverage in EXACT RATIONAL ARITHMETIC, with no floating point.

Which pixels a triangle covers is a question about exact geometry: three edge functions
and their signs. `fractions.Fraction` answers it without rounding, so a disagreement with
the rasterizer is a mistake in the geometry and not a last-bit difference -- which is what
makes this an independent reader rather than a transcription of the same arithmetic.

The scenes are chosen so every coordinate is exact in binary floating point (halves and
small integers), which is what lets an exact reference and a float one be compared with no
tolerance at all. That is deliberate on both sides: it separates "the geometry is wrong"
from "the arithmetic rounded", and only the first is a bug in a rasterizer.

WHAT IS AND IS NOT INDEPENDENT HERE, said plainly:

  COVERAGE and the DEPTH TEST are decided in Fractions and compared exactly. Independent.

  THE FILL RULE is shared. It is a definition -- which side of a tie a boundary pixel
  falls on -- and two implementations of a definition are the same definition. What
  establishes the rule instead is test/raster_props.mere, which asks whether two triangles
  sharing an edge cover it exactly once, and that needs no reference at all.

  THE COLOUR AND DEPTH VALUES are computed here in float by the same formulae. That is a
  transcription and is labelled as one: what it catches is a transposed index or a weight
  attached to the wrong vertex, not a rounding difference.

  mere test/raster_dump.mere | python3 scripts/raster_oracle.py
"""
import struct, sys
from fractions import Fraction as F

W = H = 16

def edge(ax, ay, bx, by, px, py):
    return (bx - ax) * (py - ay) - (by - ay) * (px - ax)

def is_top_left(ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    return (dy == 0 and dx > 0) or dy < 0

def accept(e, tl):
    return e > 0 if e != 0 else tl

def raster(tri, target, cull):
    """tri: three (x, y, z, iw, r, g, b) with x, y, z, iw as Fractions."""
    (ax, ay, az, aiw, ar, ag, ab), (bx, by, bz, biw, br, bg, bb), (cx, cy, cz, ciw, cr, cg, cb) = tri
    area = edge(ax, ay, bx, by, cx, cy)
    if area == 0 or (cull and area < 0):
        return
    if area < 0:
        # the same swap the rasterizer makes, so the rule always sees a clockwise triangle
        (bx, by, bz, biw, br, bg, bb), (cx, cy, cz, ciw, cr, cg, cb) = \
            (cx, cy, cz, ciw, cr, cg, cb), (bx, by, bz, biw, br, bg, bb)
        area = -area
    tl0 = is_top_left(bx, by, cx, cy)
    tl1 = is_top_left(cx, cy, ax, ay)
    tl2 = is_top_left(ax, ay, bx, by)
    for y in range(H):
        py = F(2 * y + 1, 2)
        for x in range(W):
            px = F(2 * x + 1, 2)
            e0 = edge(bx, by, cx, cy, px, py)
            e1 = edge(cx, cy, ax, ay, px, py)
            e2 = edge(ax, ay, bx, by, px, py)
            if not (accept(e0, tl0) and accept(e1, tl1) and accept(e2, tl2)):
                continue
            # COVERAGE is decided above, exactly. From here the VALUES are followed in
            # float, operation for operation, because that is what the subject computes
            # and the two are being compared bit for bit. Computing z exactly instead --
            # which the first version of this did -- makes the reference right and the
            # comparison wrong: the exact weights sum to 1 and the float ones do not, so
            # every depth came out 1 ulp apart and said "disagree" about arithmetic that
            # was doing exactly what it should.
            inv_area = 1.0 / float(area)
            w0 = float(e0) * inv_area
            w1 = float(e1) * inv_area
            w2 = float(e2) * inv_area
            z = w0 * float(az) + w1 * float(bz) + w2 * float(cz)
            i = y * W + x
            if not (z < target["depth"][i]):
                continue
            iw = w0 * float(aiw) + w1 * float(biw) + w2 * float(ciw)
            inv = 1.0 / iw
            def chan(va, vb, vc):
                return (w0 * va * float(aiw) + w1 * vb * float(biw) + w2 * vc * float(ciw)) * inv
            def q(v):
                s = v * 255.0
                return 0 if s <= 0.0 else (255 if s >= 255.0 else int(s + 0.5))
            target["depth"][i] = z
            target["color"][i] = (q(chan(ar, br, cr)), q(chan(ag, bg, cg)), q(chan(ab, bb, cb)))

def new_target():
    return {"color": [(0, 0, 0)] * (W * H), "depth": [1.0] * (W * H)}

def v(x, y, z, iw, r, g, b):
    return (F(x), F(y), F(z), F(iw), r, g, b)

# The same five scenes as test/raster_dump.mere, written out rather than shared, so a
# change to one and not the other shows up as a disagreement instead of silently agreeing.
def scenes():
    out = {}

    t = new_target()
    raster((v(2, 2, 0, 1, 1.0, 0.0, 0.0), v(13, 3, 0, 1, 1.0, 0.0, 0.0), v(4, 12, 0, 1, 1.0, 0.0, 0.0)), t, True)
    out["integer"] = t

    t = new_target()
    h = lambda n: F(2 * n + 1, 2)
    raster((v(h(2), h(2), 0, 1, 0.0, 1.0, 0.0), v(h(12), h(2), 0, 1, 0.0, 1.0, 0.0), v(h(12), h(12), 0, 1, 0.0, 1.0, 0.0)), t, True)
    raster((v(h(2), h(2), 0, 1, 0.0, 0.0, 1.0), v(h(12), h(12), 0, 1, 0.0, 0.0, 1.0), v(h(2), h(12), 0, 1, 0.0, 0.0, 1.0)), t, True)
    out["halfint"] = t

    t = new_target()
    raster((v(h(1), h(1), F(1, 2), 1, 1.0, 0.0, 0.0), v(h(14), h(1), F(1, 2), 1, 1.0, 0.0, 0.0), v(h(1), h(14), F(1, 2), 1, 1.0, 0.0, 0.0)), t, True)
    raster((v(h(3), h(3), F(-1, 4), 1, 0.0, 1.0, 0.0), v(h(12), h(3), F(-1, 4), 1, 0.0, 1.0, 0.0), v(h(3), h(12), F(-1, 4), 1, 0.0, 1.0, 0.0)), t, True)
    raster((v(h(5), h(5), F(3, 4), 1, 0.0, 0.0, 1.0), v(h(11), h(5), F(3, 4), 1, 0.0, 0.0, 1.0), v(h(5), h(11), F(3, 4), 1, 0.0, 0.0, 1.0)), t, True)
    out["depth"] = t

    t = new_target()
    raster((v(h(1), h(1), 0, 1, 1.0, 0.0, 0.0),
            v(h(14), h(2), F(1, 4), F(1, 4), 0.0, 1.0, 0.0),
            v(h(2), h(14), F(1, 2), F(1, 2), 0.0, 0.0, 1.0)), t, True)
    out["perspective"] = t

    t = new_target()
    raster((v(h(2), h(2), 0, 1, 1.0, 1.0, 0.0), v(h(3), h(13), 0, 1, 1.0, 1.0, 0.0), v(h(13), h(4), 0, 1, 1.0, 1.0, 0.0)), t, False)
    out["backface"] = t
    return out

def bits(x):
    u = struct.unpack('<Q', struct.pack('<d', float(x)))[0]
    return (u >> 32, u & 0xFFFFFFFF)

def main():
    got, cur = {}, None
    for line in sys.stdin:
        t = line.split()
        if not t:
            continue
        if t[0] == "scene":
            cur = t[1]; got[cur] = {}
        elif t[0] == "p" and cur is not None:
            got[cur][int(t[1])] = (int(t[2]), int(t[3]), int(t[4]), int(t[5]), int(t[6]))

    exp = scenes()
    bad, checked, covered = [], 0, 0
    for name, t in exp.items():
        if name not in got:
            bad.append(f"{name}: the dump has no such scene"); continue
        for i in range(W * H):
            checked += 1
            r, g, b = t["color"][i]
            zh, zl = bits(t["depth"][i])
            if (r, g, b) != (0, 0, 0):
                covered += 1
            if got[name].get(i) != (r, g, b, zh, zl):
                bad.append(f"{name} pixel {i} ({i % W},{i // W}): dump {got[name].get(i)} vs oracle {(r, g, b, zh, zl)}")
    # A reference that agreed about an empty picture would agree about anything.
    if covered < 100:
        print(f"raster_oracle: FAIL -- only {covered} pixels were covered in total, which is not a scene")
        return 1
    print(f"raster_oracle: {checked} pixels over {len(exp)} scenes, {covered} covered, exact rational coverage")
    for b in bad[:8]:
        print("  " + b)
    if bad:
        print(f"raster_oracle: FAIL ({len(bad)} disagree)")
        return 1
    print("raster_oracle: ok")
    return 0

sys.exit(main())
