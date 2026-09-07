# The corpus, and what is deliberately not in it

The north star of this project is the **66 models Khronos tags `core`** in
[glTF-Sample-Assets](https://github.com/KhronosGroup/glTF-Sample-Assets), read and drawn
and compared. This file records which of them are here, which are not, and why — so that
"how much of the corpus does this cover" is a question with a written answer rather than
a count of directories.

## The size cap: 2 MB per container variant

**49 of the 66 are here, and they cost 19.6 MB** (12.7 MB of `glTF` and 6.9 MB of
`glTF-Binary`). Both variants of each, deliberately: the same scene in two containers is
its own oracle, and `scripts/gltf_check.sh` requires the loader to produce identical
accessor data from both, needing nothing installed.

**The other 17 cost 215 MB**, and every one of them is over the cap for the same reason —
a texture atlas, usually several at 2048² or 4096². The cap buys the whole feature
surface for a tenth of the bytes, because glTF's *features* live in the small models:
Khronos writes a dedicated one for each thing a loader can get wrong.

```
Sponza 53   SciFiHelmet 30   AntiqueCamera 18   Corset 13   BarramundiFish 12
MetalRoughSpheres 11   BoomBox 11   BoomBoxWithAxes 10   Lantern 10   WaterBottle 9
Avocado 8   CompareAmbientOcclusion 5   CompareAlphaCoverage 4   DamagedHelmet 4
VirtualCity 3   BrainStem 3   AlphaBlendModeTest 3                       (MB, glTF)
```

**What the cap costs in coverage**, named rather than left to be discovered:

- `AlphaBlendModeTest` and `CompareAlphaCoverage` are the models that put OPAQUE, MASK and
  BLEND side by side. BLEND is not implemented, so nothing here draws order-dependent
  transparency — and no model here would notice.
- `CompareAmbientOcclusion` and `DamagedHelmet` are the occlusion-texture models.
- `MetalRoughSpheres` is the *textured* metallic-roughness grid;
  `MetalRoughSpheresNoTextures` is here and sweeps the same two factors without them.
- `Sponza`, `VirtualCity` and `BrainStem` are the scale models — many nodes, many
  primitives, many draw calls. Nothing here says what happens at that size.

Any of the 17 can be raised as a **named exception** when a feature lands that only it
covers. That is the intended way for this list to change; the wrong way is to notice
later that a whole capability had no witness.

`Synthetic` is not from Khronos: `scripts/gen_synthetic_gltf.py` writes it, to reach
accessor component types and shapes that no sample model uses. It is validated by the
Khronos validator precisely because a differential test over a file this repository
invented would otherwise show two readers agreeing about bytes we chose.

## Fetching

`sh scripts/vendor_gltf.sh` takes the 49 by raw URL — **the 1.7 GB repository is not
cloned** — and writes a `PROVENANCE` beside each with the URL, the date and a SHA-256 per
file. A snapshot with no date is a file from an unknown year, and one with no digest
cannot be told from an edited one.
