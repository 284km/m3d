# m3d

A 3D renderer in [Mere](https://merelang.org/), built to run glTF.

```
m3d model.glb --out picture.png --size 512
```

It reads both glTF containers, walks the scene graph, transforms and rasterizes
with a z-buffer, shades with glTF's metallic-roughness material, samples PNG
textures and writes a PNG. Every gate below runs on every commit.

## Building

Needs a built `mere` and a C compiler. Its Mere dependencies — `contrib/json`,
[mjpeg](https://github.com/284km/mjpeg), [mpng](https://github.com/284km/mpng),
[mgz](https://github.com/284km/mgz), and `contrib/raster` and `contrib/window` for
the windowed viewer — are vendored under `.mere_modules/` and committed, so a
checkout builds without fetching anything. Only the viewer needs SDL2, and only
`scripts/screen_check.sh` needs it to run.

```
mere -c src/main.mere > m3d.c && clang -O2 -w -fbracket-depth=4096 m3d.c -o m3d -lm
./m3d test/data/gltf/Box/glTF-Binary/Box.glb --out box.png --size 512
```

**`-fbracket-depth` is not optional on stock clang, and it is why every CI run was red
for the life of this project.** Mere emits a program's top-level `let`s as one nested
statement expression, so the bracket nesting of the emitted `main()` grows with the
number of bindings in the program and everything it imports — about two levels per
binding, measured, and m3d's `main()` is at 533. Clang's default limit is 256: Ubuntu's
clang 18 enforces it, Apple's clang does not, and gcc has no such limit.
`scripts/ccflags.sh` is where the gates get the flag, and it adds it only if the
compiler accepts it.

**Compiled and not interpreted, and that is not a preference**: the interpreter
takes minutes per frame where the C backend takes under a second.

The gates:

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

## Textures

`src/texture.mere` loads a PNG as RGBA8 — palette expanded, grey broadcast,
alpha filled in — and samples it, nearest or bilinear, with glTF's three wrap
modes. The PNG comes through [mpng](https://github.com/284km/mpng) and
[mgz](https://github.com/284km/mgz), both written in Mere and vendored here, so
the whole path from file to lit pixel is one language.

**Which slot is sRGB and which is linear is a property of the slot, not the
file.** glTF says baseColor and emissive are sRGB-encoded and that normal,
metallicRoughness and occlusion are not, and a PNG cannot tell you which it is.
So `Tex.sample_srgb` and `Tex.sample_linear` are separate names with no default:
decoding a normal map through the transfer curve is subtly wrong everywhere and
obviously wrong nowhere.

Two things the code says because they are easy to get backwards. The transfer
curve is applied **before** the blend, not after — the curve is not linear,
which is the entire point of it, and averaging then decoding makes edges
between light and dark go dark. And **alpha never goes through it**: alpha is a
coverage fraction and was never on a curve.

**What an image is comes from its bytes, not from its name.** glTF carries a
`mimeType` for an image in a bufferView and a uri with an extension for one
beside the document, and both can lie — a file called `.png` holding a JPEG
happens, and an extension is absent entirely from a `data:` URI. The first bytes
are the format saying what it is. Anything that is neither a PNG nor a JPEG is
refused with its first four bytes in the message, because "not an image I know"
and "a WebP" are different things to be told and the second says what to
implement.

`scripts/tex_oracle.py` decodes the same files with **PIL** — a different PNG
implementation, in another language — and compares every texel exactly. This is
the one part of the project where a real second implementation is available off
the shelf, and it would be strange not to use one.

Same corpus hole as before, and measured the same way: the two PNGs in the
vendored glTF models are **palette and RGB only**, so grey, grey-with-alpha,
RGBA and the 16-bit path had no coverage. `scripts/gen_test_png.py` writes small
images that reach them, with a **non-identity palette** so a decoder that used
the index as the colour would fail rather than pass.

The renderer reaches this module through `Render.base_tex`, which resolves a
primitive's `baseColorTexture` — texture, sampler, image — and decodes it. An
image is read either from a file beside the document or from a range of the
binary chunk, because a `.glb` carries its textures the second way and a reader
with only the first passes on this corpus and fails on everything anyone ships.
`minFilter` is read and **ignored**: there are no mipmaps, so a texture squeezed
into fewer pixels than it has texels aliases, and that is the largest remaining
disagreement with the reference renderer rather than something hidden.

**Until the reference gate went in, this module had no caller at all.** It was
complete, it had an oracle, and `render.mere` sampled nothing — so the duck
rendered white and every gate was green. See the fourth column below.

## The north star

`scripts/northstar_check.sh` asks the question the project exists for: given a
glTF file, does a picture come out. Three columns per model — **reads**,
**draws**, **lit**.

The third earns its place, and it was earned the hard way. An earlier version
culled every front face and drew the back ones: a box is still a box from the
inside, and the whole model came out one flat ambient colour. **A silhouette is
not evidence that the right triangles were drawn.** glTF's front face is
counter-clockwise, the viewport transform flips y, a flip reverses winding, and
the rasterizer's convention is that clockwise is the front — get that chain
wrong and the picture still looks like the model.

"Lit" is decided **per model** and not against a threshold: the same file is
rendered again with the directional light black, and lit means the light made a
difference. A fixed threshold cannot do it — glTF's default material is fully
metallic, so its ambient is zero, and the threshold that passes a lit metal also
passes a black frame. Two models sat exactly on that line and the column said
"no" about a renderer that was working.

### The known-refusal list is empty, and it stays

The gate holds a list of models it expects to be refused, and it holds it **in both
directions**: a refusal that is not on the list fails, and a model on the list that has
started reading fails too. That second half earned its keep twice. The list was six
models with JPEG textures; when [mjpeg](https://github.com/284km/mjpeg) landed, four of
them started reading and the gate said *"6 model(s) are on the known-refusal list but 2
were refused"* rather than passing with a stale entry. When mjpeg learned progressive
with spectral selection, `CesiumMilkTruck` followed and it said so again.

**It is now empty: 50 of 50 read.** The last two were progressive JPEGs and they took the
two halves of progressive separately — `CesiumMilkTruck`'s four scans all have
`Ah = Al = 0`, so spectral selection alone opened it, and `CesiumMan`'s ten-scan script
needed successive approximation, where a scan adds a lower bit to what an earlier one
sent. Its 1024×1024 texture decodes **0 of 3,145,728 bytes different** from libjpeg.

The empty list stays, and so does the accounting around it. An empty list is the
strongest form of the check — any refusal at all is now a failure, by name — and deleting
the mechanism because it happens to have nothing in it is how a corpus quietly starts
tolerating one again.

## Per-pixel shading

The rasterizer has two entry points. `Raster.triangle` interpolates a colour;
`RasterS.triangle` interpolates the *attributes* — world position, normal,
texture coordinate, vertex colour — and calls a shader at every covered pixel,
so a highlight lands where the surface points at the light rather than where a
vertex happens to be. The interpolated normal is re-normalized, because
interpolating three unit vectors gives a short one and a short normal darkens
the middle of every triangle in a way that looks like faceting and is not.

**A second entry point and not a replacement**, on purpose: everything in the
first is pinned by an exact-rational reference and by the coverage properties,
and rewriting it to carry eleven attributes would have put that behind a change
rather than beside one. The coverage rule, the top-left test and the depth
comparison are literally the same functions.

**The north-star table cannot see this change at all.** Every model in the
corpus is flat-faced, and when a triangle's three normals are equal the two
paths agree exactly — the numbers were identical before and after. So the check
is a property: one triangle, three normals fanned apart, drawn both ways. They
differ by up to 47 levels out of 255 in the middle, and they agree *exactly*
when the three normals are the same. Both halves are needed; the second is what
stops the first from passing for a per-pixel path that is simply wrong.

## The derived tangent frame, and the sign a mean could not see

Where a file supplies `TANGENT` the normal map is applied from it. Where it does not,
glTF says to derive a frame from the texture coordinates, and that path was **written
and turned off** for two slices: switching it on made every model that needed it *worse*
against the reference.

`Tangent.of_triangle` in `src/linalg.mere` is Lengyel's formula as a function of six
vectors — three positions, three UVs — which puts it in the file compared across all
four backends, with nine properties holding it to answers computed by hand. Turning it
on measured **NormalTangentTest 4.26 → 4.66, CompareNormal 5.72 → 8.14, Box With Spaces
0.26 → 0.41**: within about 1% of what the older screen-space derivation had measured.
**Two independent derivations agreeing on a bad answer is not a derivation problem**, so
the next measurement was not another sign.

**A pixel-wise mean cannot tell "right pattern, wrong sign" from "no pattern" — it
rewards blur.** A smooth surface sits near the average of a bumpy one and takes a
moderate penalty everywhere; a sharp pattern lit from the wrong side takes a large one at
every edge. Two instruments that can:

- **the correlation of the map's effect** — *(ours with the map) − (ours without)*
  against *(the reference) − (ours without)* — which asks whether the same thing happened
  in the same places rather than how far apart two numbers are; and
- **the file's own tangents as an oracle**: `NormalTangentMirrorTest` with its `TANGENT`
  attribute *stripped*, rendered by the derived path and compared against the same model
  rendered from the tangents it ships. That model exists for its mirrored half, so it is
  the one place a handedness error cannot hide.

| at 512×512 | correlation | stripped-model MAE |
|---|---|---|
| `B = +dP/dv` | 0.51 | 3.79 — no better than not applying the map (3.49) |
| `B = −dP/dv` | **0.996** | **0.000**, 0.1% of pixels differing |

**glTF's texture origin is the top left**, so `v` grows *down* the image and the tangent
space's second axis is `−dP/dv`. A third reading agreed: over all 5,240 triangles of that
model the derived T matches the file's to `cos +1.0000` and the derived `dP/dv` matches
its bitangent to `cos −1.0000`.

With the sign right, the three rows that needed the derivation moved to **CompareNormal
0.65, NormalTangentTest 0.44, Box With Spaces 0.11**, and the two models that supply
tangents did not move at all.

**The repository's own property could not have found this**, and that is worth stating.
Its quad's `v` grows *upward*, so `+dP/dv` *is* the supplied `w = +1` frame there — the
derived path agreed with the document and disagreed with three.js. The property now pins
the convention with a pair: the derived frame must equal the supplied one at `w = −1`
**and** differ from it at `w = +1`, which no single sign can fake. Both halves were
poisoned.

## Two bugs it found in its own dependencies

Rendering a frame of shaded spheres turned up a real one in the PNG path, and
it took two commits in two other repositories to fix:

- **mgz's DEFLATE aborted.** RFC 1951 gives the code-length alphabet at most 7
  bits where the literal and distance trees get 15, and the fallback that
  handles an over-wide tree checked the other two and never that one. A 32×32
  image of random pixels is enough — and it is *data dependent*: 16, 48, 64, 96
  and 128 square all encode fine.
- **mpng called `deflate_dynamic` past the fallback.** Once the abort became a
  graceful empty return, that turned into an **empty IDAT** — a corrupt PNG,
  which is quieter than a crash.

The regression test in mgz is worth a look for its shape: **a sweep of random
byte strings does not reproduce the bug**, measured, so the 3,104 bytes that a
real caller produced are committed as a fixture instead.

## The fourth column: agreement with three.js

Every other gate here compares this renderer against itself, against a second
reading of the same specification, or against exact arithmetic.
`scripts/reference_check.sh` points **three.js** at the same glTF file and
compares the pictures. (`scripts/ref_setup.sh` fetches a pinned three.js; the
gate skips itself, by name, if that or Chrome or Pillow is missing.)

**It is handed the camera rather than asked to guess it.** Most sample models
carry no camera, so a viewer invents one from the scene's bounds, and two
viewers will not invent the same one. This program prints the camera it
computed — as the *tangent* of the half angle, so not even a `tan` sits between
the two — and the reference is given those numbers. Otherwise the gate would be
measuring two framing heuristics.

**It found a real hole immediately.** The texture module was complete, had its
own PIL oracle, and **nothing called it**: `render.mere` sampled no texture at
all. Every gate passed, because the silhouette was right and the lighting was
right and the duck was simply *white*. Base-colour textures are wired in now,
and glTF images that this reader cannot handle — a `texCoord` other than 0, a
`data:` URI, a non-PNG — are **refused by name** rather than quietly replaced
by the material's factor, which is what produced the white duck.

Each model is rendered by the reference **twice**, because stock three.js
departs from glTF's normative appendix in three ways this renderer deliberately
does not follow:

- it **compensates for multiple scattering** in the direct specular term, off a
  DFG lookup table. Single-scatter GGX loses about 45% of its energy at
  roughness 1, so a rough metal is nearly twice as bright there. That is the
  whole of `Triangle`'s and `SimpleMeshes`' disagreement — both use glTF's
  default material, which is metallic 1, rough 1;
- it **omits the `(1 - F)`** in front of the diffuse lobe, making every
  dielectric about 4% brighter than the specification asks;
- it **interpolates F0 toward the base colour** instead of mixing two whole
  BRDFs, which is the shortcut this project measured at up to 30% wrong and
  chose not to take.

There is a fourth, and it was the biggest single cause in the whole table:
**`geometryRoughness`**, which is not in glTF at all. three.js measures how fast
the normal changes *across the screen* and adds that to the roughness, as a
specular-antialiasing hack — large on a dense curved smooth metal, zero on a flat
box. It was found last, by noticing that turning mipmaps off moved every textured
model *except* `Suzanne`: patching it takes Suzanne from 12.27 to 1.53,
`MetalRoughSpheres` from 10.8 to 0.40, `MorphStressTest` from 10.3 to 8.6. The
F0 shortcut had been blamed for MetalRoughSpheres' 8.9; the truth is it is worth
at most 0.4 there.

So there are three reference renders per model: stock, patched to glTF's BRDF,
and additionally with minification off. **Against that one, `Triangle` is
byte-identical: every pixel, every channel.** `SimpleMeshes`, `BoxInterleaved`,
`BoxVertexColors` and `Box` differ by a single least-significant bit on 0.1% to
10% of their pixels, which is a float32 GPU and a float64 CPU rounding the same
shading to the same byte. `BoxTextured`, `Duck` and `Cube` are minification:
three.js builds mipmaps and this renderer has none. All of it is written down,
with the numbers, in `scripts/ref/pinned.txt`.

Two things about the gate's shape were learned by breaking it:

**Pinning only against stock three.js would have rewarded a specification
violation.** Deleting glTF's `(1 - F)` from the shading makes this renderer
*agree more* with stock three.js — `Box` improves from 1.0 to 0.1 — because
three.js has the same omission. The patched column is what catches it.

**A gate that frames its own output cannot see a bug the framing absorbs.**
`Duck`'s root node is a uniform scale of 0.01. Make the loader ignore node
matrices and the duck becomes a hundred times bigger — *and the auto-camera
grows with it, to the pixel*, so this program's own picture is byte-identical
under that bug. Only a second renderer, handed that hundred-times camera while
drawing the correctly scaled duck, can see it. It comes out as IoU 0.000.

The gate also carries its own proof of life: the reference page paints a
four-pixel strip below the canvas *after* three.js returns, and a screenshot
without it is retaken and then refused. Headless Chrome sometimes screenshots
before the compositor has drawn, and what it writes is a valid PNG of the right
size in the right background colour — an answer to a different question, which
this gate produced once before the strip existed.

## What 49 models found that 10 did not

The corpus was ten models. The north star of this project is the **66 Khronos tags
`core`**, and pointing the four columns at 49 of them — everything under a 2 MB
cap, written down in `test/data/gltf/CORPUS.md` along with what the cap costs —
turned up six real defects in an afternoon. Every one of them was found by a
model Khronos wrote specifically to find it.

**PNG bit depths below 8 were unreadable.** A 4-bit palette row of 1000 pixels is
500 bytes; the stride came out 1000, and the unfilter loop walked off the end of
the image. Two core models are 4-bit palettes. Fixed in
[mpng](https://github.com/284km/mpng): the bytes a row occupies *in the file* are
not the bytes it occupies in the *decoded output*, and those had been one
function. Below 8 bits the filters reconstruct in packed bytes and the expansion
happens afterwards — the other order decodes 8-bit images perfectly and every
4-bit one into noise, because `left` would be a different byte from the one the
encoder subtracted.

**A glTF URI is percent-encoded and a filename is not.** `Box%20With%20Spaces.png`
went to the filesystem verbatim. `+` is *not* a space here — that is form
encoding, and `a+b.png` is a real file.

**`doubleSided` was ignored**, so the back faces of twelve of the 49 were holes.
The half that matters is the normal: a back face's points away from the eye and
glTF says to negate it there, and without that the far side of a surface is lit
from behind and comes out at ambient — a dark shape that reads as a hole which
happens not to be transparent.

**A mirroring transform reverses the winding order** (glTF 3.7.4) and did not, so
`NegativeScaleTest` was inside out — and still looked like the model, which is
the second time that particular trap has been sprung here.

**Four of the five texture slots were missing.** metallicRoughness (roughness in
*green*, metallic in *blue* — the other ordering is a different format's and
produces a plausible picture), occlusion (which multiplies the *ambient* term
only; applying it to the directional light is what makes creases look painted
on), emissive, and a second texture-coordinate set, because glTF gives every slot
its own `texCoord` and two models use the second one. `MultiUVTest` went from a
colour error of **137 to 2.4**.

**A palette PNG's transparency is a separate chunk.** No alpha channel exists, so
`tRNS` lists it one byte per entry — and the chunk may be *shorter* than the
palette, every entry past its end being opaque. Reading 255 everywhere left
glTF's MASK alpha mode with nothing to cut, and two models drew their labels as
opaque rectangles.

Two of those were found only because the reference gate compares silhouettes, and
two only because it compares colour. And two more things came out of the gates
themselves:

**mpng's own suite had a `refuse_*` arm with no input**, since the file was
written. An IHDR naming a colour/depth pair RFC 2083 does not define is now
refused by name, so that arm is a check rather than a place one could go.

**The texture oracle was not asking PIL about palette images.** It looked the
index up in the palette by hand and hardcoded alpha 255 — re-implementing the
thing an oracle exists to avoid re-implementing, and wrong in exactly the way
`tRNS` exposes. It also compared a hand-written list of six names while the dump
produced eight, and printed "over 6 images" as a literal, so adding the two
`tRNS` cases changed nothing at all. It now iterates what it was given and says
which.

**And the silhouette measure was answering a colour question.** Against the
default dark background a dark surface reads as no surface: `Suzanne` sat at IoU
0.919 with nothing wrong with its geometry, and *adding a texture slot moved that
number*, which is how a silhouette measure tells you what it is really
comparing. Both renderers now clear to magenta, through a new `--bg R,G,B`.
Magenta is not a proof — a magenta emissive surface would still fool it — and the
exact answer is two renders on two backgrounds, which is not paid for and is said
so in the code.

## Morph targets

A target is a **displacement**, not an alternative shape: its `POSITION` is how
far each vertex moves, not where it ends up. Reading them as absolute positions
collapses a mesh toward the origin, which looks like a scale bug a long way from
the material that caused it.

The weights come from **the node if it has them and the mesh otherwise** — that
order is the specification's, so that two nodes can instance one mesh at two
poses. Nothing in the corpus uses the node form, which is exactly why there is a
property for it: a rule written from a specification with no witness is a rule
nobody has checked, and reversing the two passed every other property.

`SimpleMorph` went from IoU **0.336 to 1.000** and `MorphPrimitivesTest` from a
colour error of **23.9 to 0.56**. `AnimatedMorphCube` and `MorphStressTest` did
not move at all, and that is the right answer — their weights are all zero at
rest and their animations drive them, so a renderer that morphs correctly must
leave them byte-identical. Both halves are checked: a zero weight changes
nothing, *and* a full weight moves the vertex, because the first alone passes for
a renderer that ignores morph targets entirely, which is what this one did.

The property's thresholds were **measured before being asserted** — 118 pixels
unmorphed, 118 at weight 0, 105 at weight 0.5, 93 at weight 1 — and the target
displaces one vertex sideways rather than moving the whole mesh, because a change
of shape is something the auto-camera cannot absorb by reframing.

## Skinning

A vertex belongs to up to four joints and lands where their weighted average of
transforms puts it:

```
jointMatrix[j] = worldMatrix(joints[j]) * inverseBindMatrix[j]
position       = Σ weightᵢ * jointMatrix[jointᵢ] * position
```

**The mesh node's own transform is not applied**, and that is the whole thing to
get right. The specification writes the joint matrix with an
`inverse(globalTransform(meshNode))` in front and then multiplies the result by
`globalTransform(meshNode)` again — the two cancel, which is why every
implementation says "ignore the node's transform" instead. Applying it anyway
transforms the model twice, which for a rig under a rotation is a figure lying on
its side: a picture, not an error.

Joints are node indices that can point anywhere in the scene, including at nodes
the walk has not reached and at nodes that are not the mesh's ancestors, so
`Scene.world_matrices` resolves the whole tree into an array first.

**`RecursiveSkeletons` went from IoU 0.199 to 0.999** and a colour error of 1.49
to 0.03. The other five skinned models did not move a byte — and that is not
luck: their joints sit at their bind pose at rest, so every joint matrix is the
identity and skinning is a no-op. Which means **one model in the corpus can see
this feature at all**, and that is why there are seven properties for it.

Two of those properties exist because of what glTF permits rather than what the
corpus contains:

- **A zero weight's joint index is never read.** glTF allows any value in an
  unused `JOINTS_0` slot, so the test document puts **9999** there. A reader that
  looks the joint up before testing the weight walks off the end of the skin —
  which it did, and the crash says `index 9999 out of bounds (len = 2)`.
- **The node transform is ignored** — tested with a *rotation*, not a translation
  or a scale, because the auto-camera reframes those away. A rotation here
  preserves area and bounds too, so the pixel count does not move either; only
  the picture does, which is why that property compares frame hashes rather than
  counts.

And one thing the properties **do not** cover, measured rather than assumed: the
order of `worldMatrix * inverseBindMatrix`. Reversing it leaves all seven
properties passing, and moves `RecursiveSkeletons` to 0.731 and 6.5% against the
reference. The corpus row is the only witness for that, and the pin file says so.

## Points and lines

`PrimitiveModeNormalsTest` went from IoU **0.606 to 0.980** and a colour error of
5.49 to **0.39**. It was the last row below the silhouette floor, so **every row
is above it now** and no row in `pinned.txt` carries a waiver reason.

**They are unlit, and that is the reference's own answer rather than a shortcut.**
three.js's GLTFLoader swaps a glTF material for a `PointsMaterial` or a
`LineBasicMaterial` for these modes, carrying over only `color` and `map` — both
are unlit, so the normal is never consulted and the emissive factor is *dropped*.
That model's material has `emissiveFactor [0, 0.1, 0.1]` and its points and lines
do not show it. A point is **one pixel**; three.js sets `sizeAttenuation = false`
with the comment "glTF spec says points should be 1px".

A third rasterizer entry point rather than a widening of the second, for the same
reason `RasterS` was beside `Raster`: the coverage properties and the
exact-rational reference have nothing to say about a one-pixel dot. Lines are
Bresenham — a float step accumulates and a long line drifts off its own endpoint.

**`TRIANGLE_STRIP` and `TRIANGLE_FAN` are refused by name.** They change how
triangles are *assembled* from the indices and nothing in the corpus uses either,
so they would be written blind. `LINES` and `LINE_LOOP` are implemented and have
**no witness** either — but the drawing code is the strip's, which does, and the
difference is three lines of index pairing. Recorded rather than presented as
tested.

Nine properties, and two of them had to be rewritten mid-flight: the depth tests
were checked by *counting pixels*, and counting cannot see them — with no depth
test the far point simply overwrites the near one at the same pixel and the count
is still one. They read the colour now.

## Animation

`m3d <file> --time 0.4` evaluates an animation at one instant. STEP, LINEAR and
CUBICSPLINE, on translation, rotation, scale and morph weights.

At t=0.4 every animated model agrees with three.js to under **0.15**: `Fox`
0.141, `RecursiveSkeletons` 0.108, `RiggedSimple` 0.076, `RiggedFigure` 0.063,
`InterpolationTest` 0.040, `BoxAnimated` 0.028, `SimpleSkin` 0.001.

**LINEAR on a rotation is spherical.** A lerp moves along a chord, so the path is
wrong *and* the angular speed varies. But normalized-lerp and slerp **agree
exactly at t=0.5** — both give the bisector — so a test at the midpoint cannot
tell them apart at any arc width. The property is at a quarter of a 120° arc,
where the answer is exactly 30°.

**The tangents are scaled by the time delta**, and the corpus cannot say so:
`InterpolationTest`'s CUBICSPLINE tangents are all zero, so multiplying them by
anything is invisible. There is a purpose-built two-keyframe document for it —
and its keyframes are **two seconds apart**, because with `td = 1` the scaling is
still invisible.

**Which animation is played is a choice, not "all of them".** glTF doesn't say,
and "all" is not well-defined: `Fox` carries three — Survey, Walk, Run — that
drive the same bones, and they're alternatives rather than layers. three.js's
mixer *blends* concurrent clips, dividing by total weight, so three at once give
an average; applying them in order lets the last win. Neither is wrong and
they're not each other — **Fox measured 18.5 that way**, against under 0.11 for
everything else. So `--anim N` defaults to 0 and the reference is given the same
index. Fox is 0.141 now.

**And making the reference play a clip is what forced morph-weight animation.**
`SimpleMorph`'s mesh says `[0.5, 0.5]` and its animation says `[1.0, 0.0]` at
t=0. The moment the page was told to play the clip, the two renderers were
showing different shapes — IoU 0.336 — and *m3d's frame had not changed by a
byte*. An animated `weights` channel overrides the node's, which overrides the
mesh's.

Seven poisons, all reverted. Two needed new witnesses built before they could be
caught: the tangent scaling, and *which* animation is played — `InterpolationTest`'s
nine target nine separate nodes, so applying all of them still gives each node
the right value.

## On a screen

`src/main.mere` writes a PNG. `src/view.mere` opens a window and shows the same
frame, using [`contrib/window`](https://github.com/merelang/mere) over SDL2:

```
mere -c src/view.mere > view.c
clang -O2 -w -fbracket-depth=4096 view.c -o m3d-view -lm $(sdl2-config --cflags --libs)
./m3d-view test/data/gltf/Duck/glTF/Duck.gltf --size 512
./m3d-view test/data/gltf/Duck/glTF/Duck.gltf --orbit 45,20,1.5 --check
```

**It is a separate entry point, and that is the design rather than an accident.**
The window declares four SDL2 `extern fn` lines and only the C backend emits them,
so importing it into `main.mere` would end the four-backend comparison that
`linalg_check` runs over every other file here. `main.mere` writes a file and stays
portable; this one opens a window and does not. The bridge between them is one
record literal — `mere-raster`'s canvas is `{ w, h, px }` and this renderer's target
is `{ w, h, color }`, the same three fields under two names.

### A window that can be checked without anybody looking at it

`--check` renders one frame, shows it, **reads the window's pixels back**, compares
them byte for byte and exits with a verdict. `scripts/screen_check.sh` runs that
over eight models and asks a second question the first cannot:

| the question | what is compared |
|---|---|
| does the window show what the renderer painted | the readback against the paint buffer |
| is that the picture `m3d --out` writes | the readback, encoded as PNG, against the file, byte for byte |

The second exists because these are two entry points and *nothing in the first
compares them*. A window that faithfully shows a frame no other code path would
have painted passes the first question and fails the project. All eight models are
identical on both.

**A readback is normally not evidence, and here it is.** `Window.show` writes the
pixels into a block of memory and `Window.capture` reads that same block, so a
capture that short-circuited would hand back exactly what was written and the
comparison would pass while proving nothing at all. `contrib/window` fills the
block with magenta before asking SDL for the pixels, so a readback that does not
happen comes back as the poison — and replacing the readback with a no-op does
report `4096 of 4096 pixels differ, window 255,0,255`.

Eight poisons, four on the renderer and four on the gate. Two are worth the space:

- **The composite background changed to red, and nothing happened.** Not a hole in
  the gate: `Target.clear` writes alpha 255, so every pixel is opaque, source-over
  is the identity, and *no pixel's colour depends on the background*. Nothing can
  detect a change that changes nothing. Leaving one pixel transparent first makes
  it visible immediately — so the two spellings of that colour do have to agree,
  and the poison that polices it is the transparent pixel, not the colour.
- **Poisoning the picture comparison found a defect in the gate's own reporting.**
  Every model failed, so the count of passes was zero, so the vacuity guard fired
  first and announced *"every model skipped, so this gate is vacuous"* about a run
  in which nothing skipped and everything failed. Right verdict, wrong reason — and
  the wrong reason is what somebody would go and investigate. Failures are now
  reported before vacuity.

The gate runs under `SDL_VIDEODRIVER=dummy`, which is what makes it runnable with
no display — and is a real limit, recorded rather than assumed. It exercises SDL's
software path, not a GPU, a compositor or a HiDPI scale factor. **The renderer's
size is not the window's size on a HiDPI display** and the readback comes back at
the renderer's; comparing a 256-wide readback with a 128-wide painting would report
every pixel as differing with the real reason nowhere in the output, so `view.mere`
refuses that mismatch **by name** instead. Whether a real display shows this
correctly is not something this gate says.

### Orbit, pan, zoom — and how a mouse gets gated

Drag to orbit, shift-drag to pan, `+`/`-` to zoom, arrows to turn by keyboard, `r`
to return to the auto framing, Escape to quit.

**Every camera decision is arithmetic in `Frame`, and only the event decoding is in
the window.** `orbit_of`, `orbit_turn`, `orbit_zoom`, `orbit_pan` and `orbit_camera`
are pure functions on a state of `(yaw, pitch, distance, centre)`, so
`test/render_props.mere` asserts them with no display at all: the decomposition and
the rebuild are inverses, a full turn of yaw comes back, zoom scales the distance
*and* leaves the direction alone, pan there and back returns the centre *and* a
single pan actually moves it. Keeping the split exactly at "events in, arithmetic
out" is what makes any of that reachable.

**And `--orbit yaw,pitch,dist` exists so the orbit can be gated at all.** A mouse is
not something a gate can hold; a path with no way in but a person is a path with no
gate. Both entry points take the flag — degrees, and a *multiple* of the auto-framed
distance, because those are the two spellings that mean the same thing to a model of
any size — so `screen_check.sh` checks every model at two viewpoints and compares the
orbited window against the orbited file. Same move as `--time` was for animation.

The gate also asserts **the two viewpoints differ**, which is not a formality: with
`--orbit` poisoned to be ignored by *both* entry points, the two rows per model
agreed on the auto frame twice and every comparison passed. `Box` was excluded from
that check at first, on the reasoning that a cube from two angles might genuinely
look the same — **measured, it does not**, not even at 0° against 90°, because the
light is fixed in world space and turning the camera changes which face is lit. A
waiver with a plausible reason and no measurement behind it is a hole, so it is gone,
and the check now fires on all eight.

The pitch is held at 89.94° and the zoom has a floor — **and the reason for the
first one was wrong when it was written.** The comment said the basis degenerates at
exactly ±90°, where the view direction is parallel to `look_at`'s world up, and the
matrix fills with NaN. Measured, that does not happen: `cos(π/2)` in double is
6.1e-17 rather than zero, so the cross product with up is tiny but non-zero, and the
determinant comes out -1.168056431889891 against -1.1680564318898945 a degree away.
No NaN at π/2, and none at any pitch, because no double makes that cosine exactly
zero.

What the clamp actually prevents is a **tumble**. Past vertical the cosine turns
negative, the eye's horizontal offset flips sign, and the camera swings over the top
to the opposite azimuth — at pitch 1.40 the eye is at (+0.33, 3.94, +0.60), at 1.75
it is at (-0.34, 3.94, -0.63). The view inverts and a drag that was raising the
camera starts lowering it down the far side.

**Two properties died of that correction, and a third had the wrong input.** The two
asked whether the camera and its matrix stay finite at the pole; since no NaN exists,
both passed with the clamp deleted — vacuous, and caught only by poisoning. Their
replacement asks the tumble question directly. It then failed on one side only,
because the input was ±99 rad: the base pitch is 0.5404, so +99 wraps to 5.29 rad
where the cosine is +0.56 again — past vertical many times over and back on the near
side by luck. At +1.1 and −2.2 rad, just past vertical either way, all four fail
without the clamp.

**Writing the property for that floor took three tries**, and the two failures are
the interesting part:

| the property | why it passed with the floor deleted |
|---|---|
| the distance stays above zero | 40 tenfold reductions reach 1e-40, which is above zero |
| two amounts of zooming end up *near* each other | `near_` is an absolute tolerance of 0.01, and near 1e-40 every pair of numbers is inside it |
| two amounts of zooming end up **exactly** equal | — it fails, as it should |

Absolute tolerances say nothing about numbers that have collapsed toward zero, which
was the entire subject.

### `acos` is in the table and is not bound

The orbit decomposition uses `atan2` twice rather than `acos`, and that is not a
style preference. `acos` appears in the Mere compiler's builtin table — grep says
yes — and calling it says `unbound variable: acos`. `sin`, `cos`, `atan2` and `sqrt`
were each checked *by calling*, on the interpreter and the C backend, and agree to
the byte.

### A "flake" that was a defect

After the orbit landed, `reference_check` failed with `NormalTangentTest`: *never
produced a finished frame*. m3d's own output was byte-identical to the previous
commit, so only the browser side could have moved — and the gate's comment said the
misses were "on no particular model and not reproducibly."

**It failed twice in a row**, on a different one of its three renders each time. A
different frame each time looks like randomness; the *same model* twice does not.
Measured by hand at each budget:

| variant | 20 s | 60 s | 90 s |
|---|---|---|---|
| stock | miss | **finish** | finish |
| `?gltfbrdf=1` | miss | miss | **finish** |
| `?nomip=1` | miss | miss | **finish** |

(Measured in isolation on an otherwise quiet machine.)

`--virtual-time-budget` was a flat 20000 for all four attempts. Four retries against
a deterministic wall are four identical failures, which is why retrying never helped
and why the gate said "never produced a finished frame" about a page that simply
needed longer.

**It now escalates: 20 s, 60 s, 120 s, 120 s** — because a larger budget is free when
the page finishes and costs the whole of it when it does not. The budget is a *cap* on
virtual time rather than a wait, so Chrome exits as soon as the page goes idle: `Box`
takes 1.14 s at 20 s and 1.10–1.16 s at 120 s, timed three times each. But a frame
that never finishes burns the full budget and the retry loop multiplies it — a flat
120 s spent eight minutes on one frame that was never going to work. Escalating keeps
the common case at 20 s, clears an ordinary one-off flake cheaply on the second
attempt, and reaches 120 s only for a page that has already missed twice. Each retake
now prints its budget, since "retaking" four times says nothing about whether a page
is flaky or slow, and those want different fixes.

The first green run under the escalation printed exactly the shape this predicts, and
it shows **both things are true at once** — a budget that was too short, and ordinary
flake on top of it:

```
retaking NormalTangentMirrorTest.patched.png at 20000ms   -> finished at 60 s
retaking NormalTangentTest.nomip.png at 20000ms, 60000ms  -> finished at 120 s
retaking NormalTangentTest.stock.png at 20000, 60000, 120000ms -> finished on the 4th
```

That is why the retries stay as well as the escalation, and why each retake prints the
budget it was given.

**This is not fully solved, and saying so is the point.** Under heavy machine load
that model has still missed all four attempts at 120 s. The gate then refuses to
report a number and names the model — the right behaviour — but a red line there can
be the machine rather than the renderer, so the load is worth checking before
believing it.

Two of my own measurements along the way were wrong, in opposite directions:

- I nearly concluded the page was *failing* rather than slow, because 120 s did not
  help either — until `Box` produced no screenshot in the same harness. `ls`'s
  executable marker `*` had ended up inside the Chrome path in my one-off script.
- The first "raising it is free" timing put the shot inside a shell function passed
  through `declare -f` to `sh`, which does not have `declare`; it was timing nothing.
  The claim happened to survive re-measurement, but it was not evidence when I first
  wrote it down.

An unflattering number is worth suspecting the harness over — and so is a flattering
one.

## Holding the open questions to the same standard as the code

`OPEN_QUESTIONS.md` records nine questions, each claiming something is still true —
a feature the language does not have, a symptom that still reproduces, a decision
taken for a stated reason. Nothing was checking those claims, so an entry whose
symptom someone had fixed would read as open forever.

`scripts/questions_check.sh` runs them. Each entry carries one line: a backquoted
command that must exit 0 **while the question is still open**, or `none — <why>` for
a decision. **Every question must carry one**, and that rule found the first gap
immediately: Q-9, "the rasterizer runs on two backends", had no check at all.

**The second gap is the interesting one.** Q-8's check had been passing for the wrong
reason. It wrote its test program with `printf '...\{...'`, and `\{` is not an escape
any printf here expands — so the file contained a literal backslash, `mere` answered
`parse error: expected type`, and the check, a bare `! mere file`, passed because the
program did not parse rather than because a record cannot hold a `Vec`. The claim was
still true; nothing had been testing it.

That is the failure mode this whole gate is aimed at, and it shapes the design:

- **Positive checks beat negations.** Most of these questions assert a feature is
  *absent*, and a negation succeeds when its subject fails for any reason at all — no
  compiler, a misspelled flag, an unset variable. Q-9 now greps the refusal *by name*
  (`bytebuf_new has no LLVM lowering`) and requires the C backend to accept the same
  program first. Q-8 greps `__heap` and requires a plain-`int` record to run first as
  a control.
- **The gate establishes its own positive controls before running anything.** `mere
  -te` must find a builtin that certainly exists, and `MERE_SRC` must name a tree that
  actually has a `contrib/` — otherwise every "this is still absent" check is
  vacuously true and the run means nothing. If a control fails it **skips by name**
  rather than reporting green.

Poisoned four ways: a question whose verify stops holding is reported as a retire
candidate; a question with its verify deleted is reported as unchecked; a broken
compiler and a wrong `MERE_SRC` both stop the run instead of passing it.

## What a frame costs, and a gate that found a real bug on its first run

`scripts/bench_check.sh` makes **one assertion and one report**, and they are
different kinds of thing. The assertion: peak RSS for forty frames is not materially
above peak RSS for one — a frame loop that keeps its scratch grows with the frame
count. The report: frame times at two sizes, deliberately **not pinned**, because
machine load moves them by a factor of two and a gate that asserted them would be red
on a busy laptop.

**Two sizes, because a frame has two costs that have nothing to do with each other.**
At 64×64 almost all of it is per-frame setup — the node walk, the animation state, the
joint matrices. At 512×512 the per-pixel work is added on top. `Box`, with twelve
triangles, goes 1 → 4 → 15 → 60 ms across 64 → 128 → 256 → 512, exactly four times per
doubling and so purely per-pixel; `RecursiveSkeletons` costs 26 ms to produce a 64×64
image, which is all setup — and was 240 before the walk was hoisted and 177 before the
buffers stopped being re-read. One number would have blended them, and the first person to
ask "why is a twelve-triangle model slow" would have had nowhere to look. `show` is
timed separately for the same reason — it is 1 ms at every size on every model, so
compositing is not where a frame goes, but that is a *finding*, and it took separating
them to have it.

**There is no allocation total.** Mere exposes `mem_alloc` and no allocation
statistics, so there is no honest number to print and none is printed; peak RSS stands
in, from outside the process, because the language cannot be asked for that either.
Peak RSS is spelled and scaled differently on each platform — macOS `time -l` reports
bytes, Linux `time -v` reports kilobytes — so both are handled and an unrecognised one
**skips by name** rather than being read as zero, which would make the assertion pass
without measuring anything.

### The assertion fired on its first run

Forty frames of `Suzanne` took **4198 MB against 382 MB for one**. Attributing it took
three steps, and the first two answers were wrong:

| step | result |
|---|---|
| Is it the framebuffer? | **No.** At 64×64 the framebuffer is 16 KB and RSS still went 293 → 3366 MB over forty frames — about 77 MB a frame. |
| A `region` per frame? | **No help**: 384 → 4257 MB. The emitted C showed the arena acquired, swapped in, copied out of and released exactly as it should. What that *ruled out* was the scene walk. |
| Textured versus not? | **Found it.** `Box`, no textures, was flat at 25 → 27 MB. `Suzanne` went 295 → 3006. |

`slot_tex` decoded its image on **every call**, and `mat_slots` runs **per primitive** —
so N primitives sharing a material decoded the same PNG N times, every frame. Waste in
a still render; unbounded growth in a loop.

The fix is a decoded-image cache keyed by glTF image index, plus a warm pass the caller
runs **once, outside every region**. That last part is forced, not stylistic: a
`texture` holds a `ByteBuf[R]`, so one decoded inside a region may not be stored in a
cache that outlives it, and Mere rejects that **at compile time on the code path
existing**, not on it being taken. So the lookup never writes; filling is a separate
function.

**Both pieces are needed, for two different things**, and dropping either one shows:

| | Suzanne, 40 frames at 64² | Box (no textures), 40 frames |
|---|---|---|
| neither | 293 → 3366 MB | 25 → 287 MB |
| region only | 384 → 4257 MB | 25 → 27 MB |
| cache only | 293 → 621 MB | 25 → **287 MB** |
| both | 301 → **356 MB** | 25 → **28 MB** |

The scene walk is per-frame scratch and the region reclaims it; the textures must
survive every frame and the cache holds them. **Mere does not reclaim by default** —
whatever a loop allocates without saying `region` stays for the life of the process —
so neither was going to happen on its own.

### It was mostly a speed bug

The memory was the symptom the gate could see. The cost was the frame time:

| | before | after |
|---|---|---|
| Suzanne at 64² | 75 ms | **2 ms** |
| Suzanne at 512² | 103 ms | **16 ms** |
| Fox at 64² | 28 ms | **3 ms** |

Suzanne's 75 ms to produce a 64×64 image was almost entirely PNG decoding. Every
picture in the corpus is byte-identical before and after, on both entry points.

### A region does not reclaim what a frame allocates

The residual after the cache turned out to be worth chasing, because the answer is a
fact about the language rather than about this renderer:

```
200 iterations of a 4 MB bytebuf_new inside region R { }
  1 iteration    5 MB peak RSS      the allocation is real
  200 iterations 770 MB peak RSS    none of it came back
```

The emitted C says `mere_bytebuf_new((&__lang_default_region), ...)` **even for a call
written directly inside the block**: a container whose region marker is `__heap` is
allocated from the default region, and the default region is never freed. So wrapping
a frame changes nothing for the framebuffer, however the wrapping is written.

Measured on the renderer, per-frame growth converged to **3.1× the colour buffer** —
`RiggedSimple` at 64/128/256/512 grew 117/262/844/3169 KB a frame against framebuffers
of 16/64/256/1024 KB — which is the colour buffer plus a double-precision depth buffer.
The fix needs no language change: **allocate the target once and clear it**, which is
what a real renderer does. `RecursiveSkeletons` over forty frames went 1111→1621 MB
before and **1081→1143 MB** after; `RiggedSimple` is flat.

**And the walk was quadratic.** `Scene.world_matrices_at` transforms *every* node in
the document and depends only on the frame, yet it was called once per skinned node
inside the walk — the same shape as the texture decode, frame-constant work repeated
per node. Hoisting it took `RecursiveSkeletons` from 240 ms to **134 ms** for a 64×64
image. All 48 renderable models are byte-identical before and after.

**What was left, measured and named.** About **1.3 MB a frame, and the same at every
size** — 1323 KB at 64², 1360 KB at 512², where the framebuffer differs by 64×. So it
was not the framebuffer: it was the vertex data, decoded out of its accessors on every
frame and never reclaimed. That one is fixed two sections down, by caching decoded
accessors the way textures are cached; what remains after it is a different thing and
is named there.

### The file a frame opened 1,769 times

The next thing on the list was the quadratic walk above. The profile said something
else, which is the reason it was taken before the patch: on `RecursiveSkeletons`,
`sample` put **2,231 of its samples in `open`, `read` and `close`** against 387 in the
accessor planner and 316 in the sparse reader.

`Gltf.buffer` READ THE FILE, and `Acc.plan` needs a buffer for every accessor it
describes. That document has **1,769 accessors and a 106 KB `.bin`**, so a frame opened,
read and closed the same file 1,769 times — and each read allocated a copy of it that
nothing frees.

Every buffer is now read **once, at load, into one blob**, and a buffer is a *range* of
it rather than a copy. The GLB container already worked this way: `bin` was the BIN
chunk and nothing re-read it. This gives `.gltf` the shape `.glb` had, which is why the
field keeps its name.

| | 64² | 512² |
|---|---|---|
| `RecursiveSkeletons` | 177 → **26 ms** | 204 → **54 ms** |
| `Fox` | 3 → **0 ms** | 12 → **7 ms** |
| `Suzanne` | 2 → 1 ms | 15 → 15 ms |
| `Box` | 0 → 0 ms | 24 → 25 ms |

and one frame of `RecursiveSkeletons` at 256² went **1081 MB → 295 MB** of peak RSS.
Every one of the 49 pictures readable at the time is byte-identical and the one refusal
is unchanged.

**It made the reader stricter, and that was not free.** Where buffer `i` starts in the
blob has to be *derivable* from the JSON — a record cannot hold a `Vec` (Q-8), so a
table of offsets has nowhere to live — so each buffer contributes exactly its declared
`byteLength` and an accessor is bounds-checked against its buffer's declared end rather
than against the length of the file. glTF says a bufferView must fit inside its buffer
and the Khronos validator agrees, so the strict reading is the specified one; it is
recorded as Q-11 because it is strictness chosen for an implementation reason.

**The first thing it caught was this repository's own test document.** The normal-map
property builds a glTF declaring `byteLength: 264` whose four bufferViews end at 288 —
264 is what it would be if TANGENT were VEC3, and TANGENT is VEC4. It had been illegal
since tangents were added to it, and nothing noticed because the old bound was the
length of the file, which the writer makes 288.

### Decoding an accessor once, and what the frame loop still holds

With the buffers read once, the profile moved to the two functions that FIND an
accessor rather than the one that reads it: **1,921 samples in `Acc.plan` and 1,079 in
`Acc.sparse_of` against 27 in the decoder**. Both walk the JSON array of accessors as a
list, both run on every read, and `RecursiveSkeletons` performs about 1,769 reads a
frame — every animation channel is a sampler with an input and an output, every skin
has its inverse bind matrices — so a frame walked a 1,769-long list some 3,500 times.

So the decoded arrays are cached by accessor index, in a table the caller owns.

**It fills itself, and the texture cache next door cannot** — and that difference is
forced rather than chosen. A `texture` holds a `ByteBuf[R]`, so one decoded inside a
`region` cannot be stored anywhere that outlives it and Mere rejects the path outright;
that is why images are filled by a warm pass run outside. A decoded accessor is a `Vec`
**a function returned**, which by Q-10 lands in the default region no matter which
region called it — so storing one from inside a frame's region is accepted. *The rule
that leaks it is the rule that makes it cacheable.* If Q-10 is ever fixed this stops
compiling, at the `vec_set`, which is the loud failure rather than the silent one.

| | 64² | 512² | peak RSS, 1 → 40 frames at 256² |
|---|---|---|---|
| `RecursiveSkeletons` | 26 → **3 ms** (cold frame 25) | 55 → **28 ms** | 295→367 MB becomes 294→**323** |
| `Suzanne` | unchanged | unchanged | 372→422 MB becomes 372→**373** |
| `Fox` | unchanged | unchanged | 131→149 MB becomes 131→**136** |

**What still grows is a different thing, and it is now named as one.**
`RecursiveSkeletons` adds about **0.7 MB a frame** and it is no longer the vertex data:
it is the per-frame scene state — 924 world matrices, seven arrays of animation state,
the joint matrices of 84 skins — produced by functions, so allocated in the default
region, and *different every frame*, so no cache can hold it. Only Q-10 can.

### The 19 seconds were not the renderer

Rendering `Fox` at 512 to a PNG takes 19 seconds, which would make an orbiting window
useless. Timed by phase, `Target.make`, `Target.clear` and `to_png_rgb` are 0.01 s
each at every size and **the whole cost is `encode_rgb8`** — mgz's deflate, whose own
comment says "naive O(window) scan (fine for the probe; a real impl uses a hash
chain)", up to 32768 comparisons per byte. A window never encodes a PNG: the same
frame through the window path is 0.07 s, `Suzanne` at 1024 is 0.28 s, and the
million-triangle `MetalRoughSpheresNoTextures` at 512 is 0.49 s. It also explains why
every gate here runs at 128 or 192 pixels.

## What is not here yet

Ranked by what the corpus table says, rather than by what seems interesting:

- **Mipmaps** — last, and for a reason. `minFilter` is read and ignored, so a
  minified texture aliases. Implementing it **cannot make the comparison exact**:
  `gl.generateMipmap`'s filter is implementation-defined, the level of detail
  comes from screen-space derivatives, and the implementation here is a software
  GL driver rather than a document anyone can follow. Matching libjpeg's integer
  IDCT was possible because libjpeg *is* a document. So the reference is asked to
  stop minifying instead (`?nomip=1`) and the resulting number is pinned; building
  mipmaps is a question about picture quality, not about agreement.
- **Near-plane clipping**: a triangle with any vertex behind the eye is dropped
  whole, which is right for every model in the corpus and wrong for a camera
  inside geometry.
- **The GPU path.** Everything here is a software rasterizer. The window shows the
  buffer it produced; nothing is drawn by a GPU.
- **A resizable window.** The frame buffer is a fixed size, so a size change is
  refused **by name** rather than silently freezing the picture — the window is
  created without `SDL_WINDOW_RESIZABLE`, so a drag cannot cause one, but
  `SDL_WINDOW_ALLOW_HIGHDPI` is set and moving between displays of different scale
  can.
- **The last of the frame-loop growth.** `RecursiveSkeletons` — 924 nodes, 84 skins,
  no images — still grows about **0.7 MB a frame**, which is the per-frame scene state:
  924 world matrices, seven arrays of animation state and 84 skins' joint matrices,
  produced by functions and so allocated in a default region that is never freed
  (Q-10), and different every frame, so no cache can hold them. Every ordinary model is
  now flat — `Suzanne` grows 1 MB over forty frames. `scripts/bench_check.sh` prints
  the number rather than asserting it, because a threshold loose enough to admit it
  could not catch the tenfold leak the gate exists for.
- **The scene walk on a large document, on the first frame.** `RecursiveSkeletons`
  costs **25 ms** for its first 64×64 image and **3 ms** for every frame after it — all
  setup and no pixels — down from 240 when the walk was quadratic in
  `Scene.world_matrices_at` and 177 when every accessor re-read the `.bin`. The
  accessor cache is what makes the second frame cheap; **the first still pays the list
  walks**, and so does `--out`, which renders exactly one. `J.at` walks a JSON array's
  list, so indexing 924 nodes, 1,769 accessors or a skin's joints is quadratic in each.

Within the loader: **`data:` URIs** (glTF-Embedded) and matrix accessors whose
columns need 4-byte padding — both **refused by name** rather than mis-read.
Sparse accessors used to be on this list and are implemented.

Like the rasterizer, the texture and render paths are compared across two
backends rather than four, because they write into a `ByteBuf`. See
`OPEN_QUESTIONS.md`.
