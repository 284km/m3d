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
[mpng](https://github.com/284km/mpng) and [mgz](https://github.com/284km/mgz) —
are vendored under `.mere_modules/` and committed, so a checkout builds without
fetching anything.

```
mere -c src/main.mere > m3d.c && clang -O2 -w m3d.c -o m3d -lm
./m3d test/data/gltf/Box/glTF-Binary/Box.glb --out box.png --size 512
```

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

So the first render is stock — the honest "does it agree with another renderer"
number, recorded and pinned per model — and the second has the first two of
those patched back to the appendix. **Against that one, `Triangle` is
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

## What is not here yet

Ranked by what the corpus table says, rather than by what seems interesting:

- **Progressive JPEG.** Two models are refused, by name. Baseline JPEG landed as
  [mjpeg](https://github.com/284km/mjpeg) — extracted from mbrowse, where it was
  written for a browser and had only ever been handed files a browser had already
  sniffed. Asking for it as a package found two things one caller could not: it
  took a *path*, where a glTF image may be a range of the binary chunk, and it
  **stepped past a frame marker it did not know**, so a progressive file came back
  as a `0 0 0` header with no complaint. Progressive is a much larger feature than
  baseline — several scans per component, spectral selection, successive
  approximation — and `CesiumMan` and `CesiumMilkTruck` wait on it.
- **Normal mapping.** Resolved and sampled but not yet applied, which is the
  ~8-unit residual on `NormalTangentTest` and `NormalTangentMirrorTest`. Three of
  the five models that use one have no `TANGENT` — which is exactly what
  `NormalTangentTest` is for, and means generating a tangent frame from the UVs.

- **Mipmaps.** `minFilter` is read and ignored, so a minified texture aliases.
  It is the whole of the textured models' remaining colour residual.
- **Primitive modes** other than triangles — `PrimitiveModeNormalsTest` has
  points and a line strip, skipped and counted, at IoU 0.587.
- **Animation**, beyond the fact that every animated model renders its base pose
  and agrees with the reference there.
- **Near-plane clipping**: a triangle with any vertex behind the eye is dropped
  whole, which is right for every model in the corpus and wrong for a camera
  inside geometry.
- **The window and the GPU path.**

Within the loader: **sparse accessors**, **`data:` URIs** (glTF-Embedded) and
matrix accessors whose columns need 4-byte padding — all **refused by name**
rather than mis-read.

Like the rasterizer, the texture and render paths are compared across two
backends rather than four, because they write into a `ByteBuf`. See
`OPEN_QUESTIONS.md`.
