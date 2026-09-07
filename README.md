# m3d

A 3D renderer in [Mere](https://merelang.org/), built to run glTF.

**Right now it is the arithmetic and nothing else.** `src/linalg.mere` is vectors,
matrices, quaternions and the two camera projections; there is no loader, no
rasterizer and no window yet. What is here is held to three separate checks,
and the shape of those checks is the reason this exists in the order it does.

## Building

Needs a built `mere`. No dependencies of its own.

```
MERE=/path/to/mere.exe MERE_SRC=/path/to/mere-checkout sh scripts/check.sh
```

`MERE_SRC` is optional and only adds the Wasm backend, which needs that
repository's Node host; without it the Wasm column is skipped **and says so**,
because three backends agreeing is a weaker statement than four and a gate
should not quietly become weaker.

## Three readers, each seeing what the others cannot

`scripts/linalg_check.sh` runs all three, and each one exists because the
others are blind to something:

**The four backends against each other, exactly.** Everything in the exact part
of `src/linalg.mere` uses only `+ - * /` and `sqrt` — the five operations
IEEE-754 requires to be correctly rounded — so the interpreter, the C backend,
LLVM and Wasm must print the *same bits*. That check needs no oracle: they are
each other's, and a single differing bit is a bug rather than a rounding story.
It is why the trigonometry is fenced into its own part of the file.

**A second implementation, by a different route.** Four backends running one
source agree about a wrong formula as readily as a right one.
`scripts/gen_linalg_expected.py` computes the same answers with Gauss-Jordan
where this uses Laplace, a quaternion sandwich `q v q*` where this uses the
expanded closed form, and a general frustum where this writes the entries
directly. Different rounding, so it compares in ulps: 136 values, worst 16.

**The properties, with no second implementation at all.**
`test/linalg_props.mere` asks whether a cross product is perpendicular to its
inputs, whether a rotation preserves length, whether inverting and multiplying
back gives the identity. Those are facts about the *answer*; no amount of
agreement between implementations establishes them.

The division of labour was measured rather than assumed. Replacing
`Q.to_mat4` with its transpose — the inverse rotation, which is still perfectly
orthonormal, still determinant 1, still length-preserving — leaves the
four-backend check green (they all run the same source) and leaves the
orthonormality properties green too. It is caught by the second route, loudly,
and by exactly one property: that composing quaternions matches multiplying
their matrices, which fails because a transpose reverses the order.

## Exact and inexact

`sin`, `cos` and `tan` are not required by anyone to be correctly rounded, and
Mere's four backends measurably disagree in the last bit. So `src/linalg.mere`
is split: everything a glTF file needs is above the line and exact, and the
trigonometry is below it, used only by an interactive camera and by
axis-angle construction, which a file never asks for. A file gives a rotation
as a quaternion and a camera as a field of view; the first goes straight into
`Q.to_mat4`, and the second passes through `tan` once per frame.

## Conventions

Column-major, so `mat4` is four columns and element (row *i*, column *j*) is
`c<j>`'s *i*-th field — glTF's layout and OpenGL's. Right-handed, +Y up, −Z
forward, clip z in [−1, 1]. A quaternion is stored (x, y, z, w) with w last,
as glTF stores it. `M4x.inverse` returns an **option**: a singular matrix is an
ordinary thing to meet — a zero scale on a node makes one — and answering the
identity instead would be a wrong answer that survives all the way to a pixel.

## Vertex layout: measured, and not yet decided

`bench/layout.mere` transforms 200,000 points 40 times through each layout and
checks the two agree to the bit before reporting either time. Array-of-structs
12.3 ms, struct-of-arrays 11.1 ms — SoA about 10% ahead.

That number is **not** the usual argument for SoA and should not be read as
one. There is no `f32x4_load` in the language yet, so neither layout can be
read a vector at a time: both go through `vec_get`, one scalar at a time, and
what is left is the address pattern — one stride of 3 against three strides of
1. The measurement is here so that when a load builtin arrives, the before is
on record.

## Reading glTF

`src/gltf.mere` reads both containers — a `.gltf` with its buffers in separate
files, and a `.glb` with them in a BIN chunk — and turns any accessor into
numbers: all six component types, all seven accessor types, `byteStride`,
`normalized`, an accessor with no bufferView, and buffers beyond the first.

`scripts/gltf_check.sh` holds it to four readers, and each is there because the
others are blind to something:

**The two containers against each other.** They hold the same accessor data, so
the loader must produce identical numbers from both, and that check needs
nothing installed. It is also the weakest of the four, which was measured
rather than assumed: both containers run the same accessor code, so a reader
that ignores `byteStride` misreads every interleaved model and the two agree
about the misreading perfectly. What is left to it is the container handling.

Its invariant is narrower than it first looks, too. BoxTextured's `.glb` has
four bufferViews and its `.gltf` has three, because a GLB may carry an image
inside the buffer where a `.gltf` references it as a file. The scene is the
same; the document is not.

**A second implementation, exactly.** `scripts/gltf_oracle.py` reads the same
file with Python's `struct` and its own GLB walk. Both sides read the same four
bytes of a float and divide the same exact integers, so the comparison is
bit-exact and a tolerance would be hiding something. This is the one that
catches a stride.

**The Khronos validator.** The two readers above agree with each other and both
read the same specification. Neither can say whether the *file* is legal glTF —
which matters most for the synthetic model below, written by a script in this
repository.

**The malformed files are refused, by name.** Truncated, wrong header length,
bad magic, version 1, and a chunk length that is not a multiple of four. A
loader that reads a broken GLB and returns something is the failure that
reaches a picture.

### The corpus, and the hole in it

Seven models from the Khronos sample set, both containers each where both
exist, with a `PROVENANCE` recording URL, date and SHA-256. `curl` fetches
them and not this project's own code: a vendoring tool that uses the subject to
fetch the input its own gate will read is a shape worth not having.

Measured across those seven: **every accessor is componentType 5123 or 5126,
and not one is `normalized`.** Four of the six component types and the whole
normalization path had no coverage, and the gates over that corpus were green
about code they never ran. So `scripts/gen_synthetic_gltf.py` writes a model
that uses all six, both settings of `normalized`, an interleaved view, a second
buffer and every accessor type, with the values on the edges — including −128,
whose normalized form clamps at −1 rather than reaching −128/127. The Khronos
validator says that file is legal glTF, which is the part a differential test
over a file we invented cannot establish.

### Two bugs it found in the compiler

Pointing this at the language turned up two, both fixed upstream in v0.1.446–447
and both of the shape where `mere -c` emits happily and `clang` refuses:

- `contrib/json` **could not parse a number with a decimal point.** glTF is
  fractional throughout, so the format was simply unreadable. It now has a
  second number constructor, `JFloat`, kept separate from `JNum` so that `12`
  still round-trips as `12`.
- A `type` declared inside a `module` produced **a dot in a C identifier** —
  `closure_int_M.t` — in two separate places. Neither shows up unless the
  function is used as a value.

## Rasterizing

`src/raster.mere` is the triangle rasterizer: edge functions, a top-left fill
rule, a z-buffer, perspective-correct attribute interpolation and back-face
culling. Pure — a buffer in and a buffer out, nothing opened.

**The fill rule is the whole design.** Two triangles sharing an edge must cover
every pixel along it exactly once: twice double-blends and shows as a bright
seam, zero times shows as background through solid geometry.
`test/raster_props.mere` checks that directly and needs no reference, because
two implementations of the same wrong rule agree perfectly.

That property is necessary and not sufficient, which was measured rather than
argued. **Both signs in the rule were the other way round at first** — it
implemented bottom-right where it said top-left — and exactly-once still held,
because the mirrored rule is just as consistent. What pinned the convention
down was asserting the covered *set* against the half-open box `[x0,x1) ×
[y0,y1)`, pixel by pixel rather than by counting, since `[lo,hi)` and `(lo,hi]`
cover the same number of pixels and different ones.

`scripts/raster_oracle.py` decides the same coverage in **exact rational
arithmetic** — `fractions.Fraction`, no floating point anywhere — so a
disagreement is a mistake in the geometry rather than a last-bit difference.
The colour and depth *values* it follows in float by the same formulae, which
is a transcription and is labelled as one.

The split between the two was measured too: removing perspective correction
leaves every coverage property green and is caught by the rational reference at
specific pixels. Coverage is all the properties look at.

Scene coordinates are halves and small integers on purpose, so every edge
function and barycentric weight is exact in binary floating point. That
separates "the geometry is wrong" from "the arithmetic rounded", and only the
first is a bug in a rasterizer.

**It runs on two backends, not four.** `bytebuf_*` is refused by the LLVM and
Wasm backends, so the rasterizer is compared across the interpreter and C where
the linear algebra is compared across four. The gate prints the refusal rather
than passing over it; see `OPEN_QUESTIONS.md` Q-9.

## Shading, and why it is still exact

`src/shade.mere` is glTF's metallic-roughness material under directional
lights: Lambert for the diffuse lobe, Cook-Torrance with a GGX distribution and
the height-correlated Smith visibility term for the specular one.

**The plan for this file assumed shading would end the bit-exact comparison
between backends**, because sRGB is a power of 2.4 and nobody rounds `pow` the
same way twice. It does not have to:

- **sRGB is between a byte and a float in both directions.** Decoding is 256
  constants and an index; encoding is 255 thresholds and a search, each
  threshold being the smallest double the `pow` reference maps to that byte,
  found by bisecting the reference so the table agrees with it *by
  construction*. `pow` runs once per entry in `scripts/gen_srgb.py` and never
  at run time. (The tempting closed form — `decode((b - 0.5)/255)` — disagrees
  on 7 values in 200,000, because `enc(dec(x))` is not exactly `x`.)
- **The BRDF has no transcendental in it** once Schlick's Fresnel is five
  multiplies rather than `pow(x, 5)`.

Measured: the shading and sRGB tests are byte-identical across the
interpreter, C, LLVM and Wasm.

### The gap the properties had

`test/shade_props.mere` checks reciprocity — swap the light and the eye, get
the same value — which is true of a real BRDF and false of most ways of getting
the Fresnel or visibility term wrong. It also checks the Fresnel endpoints, the
absence of a diffuse lobe on a metal, and that energy does not explode.

Every one of those passed on an implementation that was **up to 30% wrong**.
The material was the usual lerp-F0 shortcut instead of the specification's mix
of two complete BRDFs, and those two agree at `metallic = 0` and `metallic = 1`
and nowhere between — which is exactly where every property was looking. The
sweep property added since (the blend is linear in `metallic`, which the
specification's form is by construction) rejects the shortcut, and *that* was
checked by running it against the shortcut rather than assumed.

## What is not here yet

Textures (PNG and JPEG decoding, sampling and wrap modes), the window,
animation and skinning, and the GPU path. Also, within the loader: sparse accessors, `data:` URIs (glTF-Embedded),
and matrix accessors whose columns need 4-byte padding — all three **refused by
name** rather than mis-read. See `OPEN_QUESTIONS.md`.
