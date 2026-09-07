#!/usr/bin/env python3
"""A second reader for the same glTF file, so that agreeing with itself is not the test.

scripts/container_check.sh already asks the loader to produce the same numbers from a
.gltf and a .glb, and that check needs no oracle -- the two containers hold the same
scene, so they are each other's. What it cannot see is BOTH containers being read wrong
the same way, because both go through the same accessor code. This is that second reader.

It is independent where it matters: `struct.unpack` against hand-assembled shifts over
`bytes_get`, and its own GLB chunk walk. It is NOT independent about what the format
means -- both sides read the same specification -- so what it catches is a mistake in the
arithmetic and the offsets, which is where the mistakes are.

THE COMPARISON IS EXACT. Both sides read the same four bytes of a float32 and widen them
the same way, and both divide an exact integer by an exact 255.0 or 32767.0, so there is
no rounding to disagree about. A tolerance here would be hiding something.

  mere test/gltf_dump.mere <file> | python3 scripts/gltf_oracle.py <file>
"""
import json, struct, sys, os

def load(path):
    """Returns (document, buffers-by-index). Its own GLB walk, not the subject's."""
    raw = open(path, 'rb').read()
    if len(raw) >= 12 and raw[:4] == b'glTF':
        ver, total = struct.unpack_from('<II', raw, 4)
        if ver != 2:
            raise SystemExit(f"oracle: GLB version {ver}")
        if total != len(raw):
            raise SystemExit(f"oracle: GLB header says {total}, file has {len(raw)}")
        doc, bin_chunk, off = None, b'', 12
        while off + 8 <= total:
            clen, ctype = struct.unpack_from('<II', raw, off)
            data = raw[off + 8: off + 8 + clen]
            if ctype == 0x4E4F534A:
                doc = json.loads(data)
            elif ctype == 0x004E4942:
                bin_chunk = data
            off += 8 + clen + (-clen % 4)
        if doc is None:
            raise SystemExit("oracle: GLB has no JSON chunk")
        base = bin_chunk
    else:
        doc = json.loads(raw)
        base = None
    bufs = []
    d = os.path.dirname(path)
    for b in doc.get('buffers', []):
        uri = b.get('uri')
        if uri is None:
            bufs.append(base if base is not None else b'')
        elif uri.startswith('data:'):
            raise SystemExit("oracle: data: URI (glTF-Embedded) is out of scope here too")
        else:
            import urllib.parse
            bufs.append(open(os.path.join(d, urllib.parse.unquote(uri)), 'rb').read())
    return doc, bufs

# The two tables, written out rather than computed, so a wrong entry is visible.
FMT  = {5120: '<b', 5121: '<B', 5122: '<h', 5123: '<H', 5125: '<I', 5126: '<f'}
SIZE = {5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4}
NC   = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4, 'MAT2': 4, 'MAT3': 9, 'MAT4': 16}
# glTF's normalized mappings. The signed ones clamp at -1 because -128/127 is past it.
NORM = {5121: lambda v: v / 255.0,
        5120: lambda v: max(v / 127.0, -1.0),
        5123: lambda v: v / 65535.0,
        5122: lambda v: max(v / 32767.0, -1.0)}

def read_accessor(doc, bufs, i):
    a = doc['accessors'][i]
    if 'sparse' in a:
        return None, None
    ct, kind, count = a['componentType'], a['type'], a['count']
    nc, cs = NC[kind], SIZE[ct]
    norm = a.get('normalized', False)
    if 'bufferView' not in a:
        return [0] * (count * nc), [0.0] * (count * nc)
    bv = doc['bufferViews'][a['bufferView']]
    buf = bufs[bv.get('buffer', 0)]
    start = bv.get('byteOffset', 0) + a.get('byteOffset', 0)
    stride = bv.get('byteStride', nc * cs)
    ints, flts = [], []
    for k in range(count):
        base = start + k * stride
        for c in range(nc):
            v = struct.unpack_from(FMT[ct], buf, base + c * cs)[0]
            if ct != 5126:
                ints.append(v)
            flts.append(NORM[ct](v) if (norm and ct in NORM) else float(v))
    return (ints if ct != 5126 else None), flts

def bits(x):
    u = struct.unpack('<Q', struct.pack('<d', float(x)))[0]
    return (u >> 32, u & 0xFFFFFFFF)

def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: gltf_oracle.py <file.gltf|file.glb>  (dump on stdin)")
    path = sys.argv[1]
    doc, bufs = load(path)

    got = {}
    cur = None
    for line in sys.stdin:
        t = line.split()
        if not t:
            continue
        if t[0] == 'acc':
            cur = int(t[1])
        elif t[0] == 'shape':
            got['shape'] = ' '.join(t[1:])
        elif t[0].startswith('i') and cur is not None and t[0][1:].isdigit():
            got[('i', cur, int(t[0][1:]))] = int(t[1])
        elif t[0].startswith('f') and cur is not None and t[0][1:].isdigit():
            got[('f', cur, int(t[0][1:]))] = (int(t[1]), int(t[2]))

    bad, checked = [], 0
    exp_shape = ' '.join(f"{k} {len(doc.get(k, []))}" for k in
                         ('accessors', 'bufferViews', 'buffers', 'meshes', 'nodes', 'materials'))
    if got.get('shape') != exp_shape:
        bad.append(f"shape: dump {got.get('shape')!r} vs oracle {exp_shape!r}")
    else:
        checked += 1

    for i in range(len(doc.get('accessors', []))):
        ints, flts = read_accessor(doc, bufs, i)
        if flts is None:
            continue
        if ints is not None:
            for k, v in enumerate(ints):
                checked += 1
                if got.get(('i', i, k)) != v:
                    bad.append(f"acc {i} int {k}: dump {got.get(('i', i, k))} vs oracle {v}")
        for k, v in enumerate(flts):
            checked += 1
            if got.get(('f', i, k)) != bits(v):
                bad.append(f"acc {i} float {k}: dump {got.get(('f', i, k))} vs oracle {bits(v)} ({v!r})")

    # A gate that compared nothing is not a gate that passed.
    if checked <= 1:
        print(f"gltf_oracle: FAIL -- only {checked} value(s) compared for {os.path.basename(path)}")
        return 1
    print(f"gltf_oracle: {os.path.basename(path)} -- {checked} values, exact, by a second reader")
    for b in bad[:10]:
        print("  " + b)
    if bad:
        print(f"gltf_oracle: FAIL ({len(bad)} disagree)")
        return 1
    return 0

sys.exit(main())
