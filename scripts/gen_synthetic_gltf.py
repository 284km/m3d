#!/usr/bin/env python3
"""Build a glTF that reaches the parts of the reader the sample models do not.

MEASURED, not assumed: across the seven Khronos models vendored here, every accessor is
componentType 5123 or 5126 and not one is `normalized`. Four of the six component types
and the whole normalization path were therefore untested, and the gates over that corpus
were green about code they never ran.

So this writes a document that uses all six component types, both settings of
`normalized`, all seven accessor types, an interleaved bufferView with a byteStride, a
second buffer, and an accessor with a byteOffset into the middle of a view. It is written
in both containers, and the values are chosen to land on the edges: 0 and 255 for a byte,
-128 whose normalized form CLAMPS at -1 rather than reaching -128/127, and the largest
unsigned int.

It is a differential input and not an expectation. What it establishes is that this
reader and scripts/gltf_oracle.py agree on bytes neither has seen before; that the file
is a legal glTF is established separately, by the Khronos validator.

  python3 scripts/gen_synthetic_gltf.py
"""
import json, os, struct

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "test", "data", "gltf", "Synthetic")

def main():
    os.makedirs(os.path.join(OUT, "glTF"), exist_ok=True)
    os.makedirs(os.path.join(OUT, "glTF-Binary"), exist_ok=True)

    views, accessors, blobs = [], [], []

    def add(data, *, stride=None, target=None, buffer=0):
        blobs.append((buffer, data))
        return len(blobs) - 1  # a placeholder; offsets are assigned after packing

    # --- buffer 0: one accessor per component type, packed ------------------
    # Edge values on purpose. -128 is the one that matters: its normalized form is
    # -128/127, which is below -1, and glTF says it clamps at -1.
    specs = [
        ("i8",  5120, "SCALAR", [-128, -127, 0, 1, 127], '<b', True),
        ("u8",  5121, "SCALAR", [0, 1, 128, 254, 255],   '<B', True),
        ("i16", 5122, "SCALAR", [-32768, -32767, 0, 1, 32767], '<h', True),
        ("u16", 5123, "SCALAR", [0, 1, 32768, 65534, 65535], '<H', True),
        ("u32", 5125, "SCALAR", [0, 1, 65536, 2147483648, 4294967295], '<I', False),
        ("f32", 5126, "SCALAR", [0.0, -0.0, 1.5, -2.25, 3.4028234663852886e38], '<f', False),
    ]
    parts = []          # (buffer, bytes) in order
    def emit(buffer, data):
        parts.append((buffer, data))
        return len(parts) - 1

    plan = []           # (part_index, stride, accessor dict without bufferView)
    for name, ct, kind, vals, fmt, can_norm in specs:
        data = b''.join(struct.pack(fmt, v) for v in vals)
        pi = emit(0, data)
        plan.append((pi, None, {"componentType": ct, "count": len(vals), "type": kind,
                                "name": name}))
        if can_norm:
            pi2 = emit(0, data)
            plan.append((pi2, None, {"componentType": ct, "count": len(vals), "type": kind,
                                     "normalized": True, "name": name + "_norm"}))

    # --- an interleaved view: VEC3 float and VEC4 unsigned-byte, stride 16 ---
    inter = b''
    for k in range(4):
        inter += struct.pack('<fff', k + 0.5, k + 1.5, k + 2.5)
        inter += struct.pack('<BBBB', k, 2 * k, 3 * k, 255)
    pi = emit(0, inter)
    plan.append((pi, 16, {"componentType": 5126, "count": 4, "type": "VEC3", "name": "inter_pos"}))
    plan.append((pi, 16, {"componentType": 5121, "count": 4, "type": "VEC4", "byteOffset": 12,
                          "normalized": True, "name": "inter_col"}))

    # --- the matrix and vector shapes, all float so no column padding is due ---
    for kind, n in (("VEC2", 2), ("MAT2", 4), ("MAT3", 9), ("MAT4", 16)):
        data = b''.join(struct.pack('<f', 0.25 * i) for i in range(n * 2))
        pi = emit(0, data)
        plan.append((pi, None, {"componentType": 5126, "count": 2, "type": kind, "name": kind.lower()}))

    # --- buffer 1, so the buffer index is exercised and not assumed to be 0 ---
    second = b''.join(struct.pack('<H', v) for v in (7, 8, 9))
    pi = emit(1, second)
    plan.append((pi, None, {"componentType": 5123, "count": 3, "type": "SCALAR", "name": "second_buffer"}))

    # --- lay the parts out, four-byte aligned, per buffer -------------------
    bufdata = {0: b'', 1: b''}
    offsets = {}
    for i, (b, data) in enumerate(parts):
        pad = -len(bufdata[b]) % 4
        bufdata[b] += b'\x00' * pad
        offsets[i] = len(bufdata[b])
        bufdata[b] += data

    for i, (b, data) in enumerate(parts):
        v = {"buffer": b, "byteOffset": offsets[i], "byteLength": len(data)}
        views.append(v)
    for pi, stride, acc in plan:
        if stride is not None:
            views[pi]["byteStride"] = stride
        a = dict(acc); a["bufferView"] = pi
        accessors.append(a)

    doc = {
        "asset": {"version": "2.0", "generator": "m3d scripts/gen_synthetic_gltf.py"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        # One node with a matrix and one with TRS, because a reader has both paths.
        "nodes": [{"children": [1, 2]},
                  {"matrix": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 1.5, -2.5, 3.5, 1]},
                  {"translation": [1.0, 2.0, 3.0],
                   "rotation": [0.2597, 0.5194, 0.7791, 0.2299],
                   "scale": [2.0, 0.5, 1.0]}],
        "buffers": [], "bufferViews": views, "accessors": accessors,
    }

    # --- glTF with external buffers -----------------------------------------
    for b in (0, 1):
        with open(os.path.join(OUT, "glTF", f"synthetic{b}.bin"), "wb") as f:
            f.write(bufdata[b])
    doc["buffers"] = [{"uri": f"synthetic{b}.bin", "byteLength": len(bufdata[b])} for b in (0, 1)]
    with open(os.path.join(OUT, "glTF", "Synthetic.gltf"), "w") as f:
        json.dump(doc, f, indent=1)

    # --- GLB: buffer 0 becomes the BIN chunk, buffer 1 stays a file ----------
    # Deliberately mixed, so the GLB path exercises both "the chunk" and "a file
    # beside the document" rather than only the first.
    gdoc = json.loads(json.dumps(doc))
    gdoc["buffers"][0] = {"byteLength": len(bufdata[0])}
    js = json.dumps(gdoc, separators=(',', ':')).encode()
    js += b' ' * (-len(js) % 4)
    bn = bufdata[0] + b'\x00' * (-len(bufdata[0]) % 4)
    glb = b'glTF' + struct.pack('<II', 2, 12 + 8 + len(js) + 8 + len(bn))
    glb += struct.pack('<II', len(js), 0x4E4F534A) + js
    glb += struct.pack('<II', len(bn), 0x004E4942) + bn
    with open(os.path.join(OUT, "glTF-Binary", "Synthetic.glb"), "wb") as f:
        f.write(glb)
    with open(os.path.join(OUT, "glTF-Binary", "synthetic1.bin"), "wb") as f:
        f.write(bufdata[1])

    with open(os.path.join(OUT, "PROVENANCE"), "w") as f:
        f.write("# Synthetic -- generated by scripts/gen_synthetic_gltf.py, not fetched.\n"
                "# It exists because the vendored Khronos models use only componentType 5123\n"
                "# and 5126 and never set `normalized`, so four of the six component types\n"
                "# and the whole normalization path had no coverage.\n")
    print(f"wrote {len(accessors)} accessors over {len(views)} views, "
          f"buffers {len(bufdata[0])} and {len(bufdata[1])} bytes")

main()
