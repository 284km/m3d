#!/usr/bin/env python3
"""An independent check on src/linalg.mere -- by a DIFFERENT ROUTE, not a transcription.

scripts/linalg_check.sh already asks the four Mere backends to agree with each other, and
that check is exact and needs no oracle. What it cannot see is all four agreeing on the
same wrong formula, because they run the same source. This file is the second reader, and
it is only worth having if it computes the answers a different way:

  inverse        Gauss-Jordan with partial pivoting, against linalg's Laplace expansion on
                 complementary minors. Nothing is shared but the answer.
  quat -> mat4   the columns are the quaternion sandwich q v q* applied to the three basis
                 vectors, against linalg's expanded closed form.
  perspective    built from the general frustum(l, r, b, t, n, f), against linalg's direct
                 entries.
  look_at        a basis matrix multiplied by a translation, against linalg's direct entries.
  trs            T, R and S built separately and multiplied, against the same.
  mat4 mul       the textbook triple loop over rows and columns, against linalg's
                 column-at-a-time formulation.

The small operations (dot, cross, add) have no second route worth writing -- a "different"
dot product is the same three multiplies -- so for those this file is a transcription and
says so. They are covered instead by the properties in test/linalg_props.mere, which need
no oracle at all: a cross product is perpendicular to both its inputs, and that is a fact
about the answer rather than about the code.

TOLERANCE, NOT BITS. Gauss-Jordan and Laplace do not round the same way, so a bit
comparison here would fail for a correct implementation. The comparison is in ulps and the
worst one is printed, so the number is visible rather than hidden behind a pass.

  python3 scripts/gen_linalg_expected.py < dump.txt
"""
import math, struct, sys

# ---- the same LCG the dump uses; integers, then one division, so both sides get the
# ---- identical doubles without either trusting the other's parser
def lcg(count, seed):
    out, x = [], seed
    for _ in range(count):
        x = (1103515245 * x + 12345) % 2147483648
        out.append((x % 2001 - 1000) / 1000.0)
    return out

def bits(v):
    return struct.unpack('<Q', struct.pack('<d', v))[0]

def ulps(a, b):
    """Distance in representable doubles. Signed zeros are zero apart; a NaN is infinitely
    far from anything, including itself, which is what we want a gate to say."""
    if math.isnan(a) or math.isnan(b):
        return 0 if (math.isnan(a) and math.isnan(b)) else float('inf')
    if a == b:
        return 0
    if math.isinf(a) or math.isinf(b):
        return float('inf')
    ua, ub = bits(a), bits(b)
    # map to a monotone ordering across the sign boundary
    ua = (1 << 63) - ua if ua >> 63 else ua | (1 << 63)
    ub = (1 << 63) - ub if ub >> 63 else ub | (1 << 63)
    return abs(ua - ub)

# ---- matrices as lists of 4 columns, each a list of 4 rows: m[col][row], glTF's layout
def mat(cols):  return [list(c) for c in cols]
def ident():    return [[1.0 if r == c else 0.0 for r in range(4)] for c in range(4)]

def matmul(a, b):
    """The textbook triple loop, over rows and columns rather than column-at-a-time."""
    out = [[0.0] * 4 for _ in range(4)]
    for c in range(4):
        for r in range(4):
            s = 0.0
            for k in range(4):
                s += a[k][r] * b[c][k]
            out[c][r] = s
    return out

def matvec(m, v):
    return [sum(m[k][r] * v[k] for k in range(4)) for r in range(4)]

def transpose(m):
    return [[m[r][c] for r in range(4)] for c in range(4)]

def inverse_gauss_jordan(m):
    """Row reduction with partial pivoting -- no cofactors, no cross products."""
    a = [[m[c][r] for c in range(4)] for r in range(4)]      # to row-major
    inv = [[1.0 if i == j else 0.0 for j in range(4)] for i in range(4)]
    for col in range(4):
        piv = max(range(col, 4), key=lambda r: abs(a[r][col]))
        if a[piv][col] == 0.0:
            return None
        a[col], a[piv] = a[piv], a[col]
        inv[col], inv[piv] = inv[piv], inv[col]
        d = a[col][col]
        a[col] = [x / d for x in a[col]]
        inv[col] = [x / d for x in inv[col]]
        for r in range(4):
            if r == col:
                continue
            f = a[r][col]
            if f == 0.0:
                continue
            a[r] = [x - f * y for x, y in zip(a[r], a[col])]
            inv[r] = [x - f * y for x, y in zip(inv[r], inv[col])]
    return [[inv[r][c] for r in range(4)] for c in range(4)]  # back to column-major

def qmul(a, b):
    ax, ay, az, aw = a; bx, by, bz, bw = b
    return (aw*bx + ax*bw + ay*bz - az*by,
            aw*by - ax*bz + ay*bw + az*bx,
            aw*bz + ax*by - ay*bx + az*bw,
            aw*bw - ax*bx - ay*by - az*bz)

def quat_to_mat_sandwich(q):
    """Rotate each basis vector by q v q*, and use the results as the columns. A different
    route from the expanded closed form: this one never writes down a 1 - 2(yy+zz)."""
    x, y, z, w = q
    conj = (-x, -y, -z, w)
    cols = []
    for e in ((1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0)):
        r = qmul(qmul(q, (e[0], e[1], e[2], 0.0)), conj)
        cols.append([r[0], r[1], r[2], 0.0])
    cols.append([0.0, 0.0, 0.0, 1.0])
    return cols

def frustum(l, r, b, t, n, f):
    """The general off-axis frustum; a symmetric perspective is one case of it."""
    return [[2*n/(r-l), 0.0, 0.0, 0.0],
            [0.0, 2*n/(t-b), 0.0, 0.0],
            [(r+l)/(r-l), (t+b)/(t-b), -(f+n)/(f-n), -1.0],
            [0.0, 0.0, -2*f*n/(f-n), 0.0]]

def perspective_from_tan(th, aspect, n, f):
    t = th * n; b = -t; r = t * aspect; l = -r
    return frustum(l, r, b, t, n, f)

def norm3(v):
    L = math.sqrt(sum(c*c for c in v))
    return [c / L for c in v] if L else [0.0, 0.0, 0.0]

def cross3(a, b):
    return [a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]]

def look_at(eye, center, up):
    """A basis matrix times a translation, composed with matmul -- not written out."""
    f = norm3([center[i]-eye[i] for i in range(3)])
    s = norm3(cross3(f, up))
    u = cross3(s, f)
    basis = [[s[0], u[0], -f[0], 0.0],
             [s[1], u[1], -f[1], 0.0],
             [s[2], u[2], -f[2], 0.0],
             [0.0, 0.0, 0.0, 1.0]]
    trans = ident(); trans[3] = [-eye[0], -eye[1], -eye[2], 1.0]
    return matmul(basis, trans)

def main():
    got = {}
    for line in sys.stdin:
        parts = line.split()
        if len(parts) == 3 and parts[1].lstrip('-').isdigit():
            hi, lo = int(parts[1]), int(parts[2])
            got[parts[0]] = struct.unpack('<d', struct.pack('<Q', (hi << 32) | lo))[0]
        elif parts:
            got[parts[0]] = ' '.join(parts[1:])

    d = lcg(64, 20260907)
    exp = {}
    def put(name, v):
        if isinstance(v, list) and v and isinstance(v[0], list):
            for ci, c in enumerate(v):
                for ri, val in enumerate(c):
                    exp[f"{name}.c{ci}.{'xyzw'[ri]}"] = val
        elif isinstance(v, (list, tuple)):
            for ri, val in enumerate(v):
                exp[f"{name}.{'xyzw'[ri]}"] = val
        else:
            exp[name] = v

    mA = mat([d[8:12], d[12:16], d[16:20], d[20:24]])
    mB = mat([d[24:28], d[28:32], d[32:36], d[36:40]])
    put("m4.mul", matmul(mA, mB))
    put("m4.mul_v4", matvec(mA, d[0:4]))
    put("m4.transpose", transpose(mA))
    inv = inverse_gauss_jordan(mA)
    put("m4.inverse", inv)
    nm = transpose(inv)
    nm = [[nm[c][r] if not (c == 3 or r == 3) else (1.0 if c == 3 and r == 3 else 0.0)
           for r in range(4)] for c in range(4)]
    put("m4.normal", nm)

    qraw = d[40:44]
    L = math.sqrt(sum(c*c for c in qraw)); q = tuple(c / L for c in qraw)
    put("q.to_mat4", quat_to_mat_sandwich(q))
    q2raw = d[44:48]
    L2 = math.sqrt(sum(c*c for c in q2raw)); q2 = tuple(c / L2 for c in q2raw)
    put("q.mul", qmul(q, q2))

    T = ident(); T[3] = [d[0], d[1], d[2], 1.0]
    R = quat_to_mat_sandwich(q)
    S = ident()
    for i in range(3):
        S[i][i] = d[3 + i]
    put("m4.trs", matmul(T, matmul(R, S)))

    put("m4.perspective", perspective_from_tan(0.5, 1.5, 0.1, 100.0))
    put("m4.look_at", look_at([3.0, 4.0, 5.0], [0.0, 0.0, 0.0], [0.0, 1.0, 0.0]))

    # ulps. MEASURED, not guessed: the widest gap is q.mul.w at 16, and that one is
    # explained rather than tolerated -- linalg's Q.normalize multiplies by 1/sqrt(l2)
    # while this file divides by sqrt(l2), which puts the two normalized quaternions 1 ulp
    # apart, and the Hamilton product's w component (aw*bw - ax*bx - ay*by - az*bz) is a
    # difference of near-equal terms that amplifies it to 16. Everything else is under
    # that. 64 leaves room for the same effect on a machine whose sqrt or division rounds
    # into a different neighbour, without leaving room for a wrong formula.
    TOL = 64
    worst, worst_name, checked, bad = 0, "", 0, []
    for k, v in sorted(exp.items()):
        if k not in got:
            bad.append(f"{k}: the dump does not contain it"); continue
        checked += 1
        u = ulps(got[k], v)
        if u > worst:
            worst, worst_name = u, k
        if u > TOL:
            bad.append(f"{k}: mere {got[k]!r} vs {v!r} ({u} ulps)")
    if checked == 0:
        print("linalg_oracle: FAIL -- nothing was checked, which is not a pass"); return 1
    print(f"linalg_oracle: {checked} values by a second route, worst {worst} ulps ({worst_name}), tolerance {TOL}")
    for b in bad[:12]:
        print("  " + b)
    if bad:
        print(f"linalg_oracle: FAIL ({len(bad)} outside tolerance)"); return 1
    print("linalg_oracle: ok")
    return 0

sys.exit(main())
