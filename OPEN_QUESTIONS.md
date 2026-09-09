# Open questions (m3d)

Decisions not yet made, written down where they can be found rather than
rediscovered. The format is the one the Mere project uses: a question, what is
known, the candidates, and — where a machine can be asked — a command that
**exits 0 while the question is still open**, so a stale entry is detectable
instead of merely embarrassing.

---

## Q-1: the vertex layout — array of structs or struct of arrays

- **State**: open, measured but not decided.
- **Measured** (`bench/layout.mere`, 200,000 points x 40, C backend): AoS 12.3 ms,
  SoA 11.1 ms, bit-identical answers. About 10% to SoA.
- **Why it is not decided**: that 10% is the ADDRESS PATTERN and nothing else.
  The reason SoA is normally chosen is that a wide lane can load four x's in
  one instruction, and the language has no `f32x4_load` — both layouts go
  through `vec_get`, one scalar at a time. Deciding now would be deciding on
  the wrong axis. AoS also has an argument the benchmark cannot see: a glTF
  accessor hands over interleaved data, so SoA costs a de-interleaving pass at
  load time that this measurement does not include.
- **Revisit when**: a load builtin exists, and the loader is written so the
  de-interleaving cost is real rather than hypothetical.
- **Verify**: `! "$MERE" -te 'f32x4_load' >/dev/null 2>&1`
  (ask the compiler, not the documentation: the stdlib reference contains the string
  `f32x4_load` in the sentence saying there is no such builtin, so a grep for it would
  report this question as answered by the paragraph explaining that it is not.)

## Q-6: is a little-endian read worth a builtin

- **State**: open, measured, and the answer is **not yet** — recorded rather than acted on.
- glTF is little-endian throughout, and `bytes_get` reads one byte, so every multi-byte
  value in the format is four reads and three shifts in `src/bytes_le.mere`. The language
  has no `bytes_get_u32le`. The question is whether that costs enough to add one.
- **Measured** (`bench/le.mere` and a C reference, 2,000,000 values x 20 passes, C backend):

  | | Mere | C, the same shifts | C, one unaligned load |
  |---|---|---|---|
  | assembling a u32 | 37 ms | 13 ms | **3.0 ms** |
  | reading an f32 **as an accessor does** | **69 ms** | -- | 66 ms |

- **The float row is the one that decides it.** A vertex buffer is float, and there Mere
  is already at C's speed: the conversion and the arithmetic dominate, and the assembly
  hides behind them. A builtin would buy nothing on the data that makes up the bulk of a
  model.
- The integer row is a real gap -- 12x against a single load -- and it is the index
  buffer, which is a fraction of the size of the vertex data. A model would have to be
  index-heavy in a way none in `test/data` is before that mattered.
- **Revisit when**: a real model's load time is measured and the index read is a visible
  share of it. Guessing that it will be is what this measurement is here to prevent.
- **Verify**: `! "$MERE" -te 'bytes_get_u32le' >/dev/null 2>&1`

## Q-7: glTF-Embedded (`data:` URIs) needs base64, which the language has as an example

- **State**: open, deliberately out of scope for the loader's first slice.
- A `data:application/octet-stream;base64,...` URI is one of glTF's three container
  shapes. The loader **refuses it by name** rather than mis-reading it as a filename.
- The language has base64 in `examples/base64_bytes.mere` -- over `bytes`, byte-identical
  on all four backends -- and *not* in `contrib/`. Two contrib modules (`auth/jwt`,
  `http/basic_auth`) already mention base64, so this would be a third consumer and the
  argument for promoting it is close to made. That promotion is a change to the language
  repository, not to this one.
- **Verify**: `! ls "$MERE_SRC/contrib/encoding/base64.mere" >/dev/null 2>&1`

## Q-8: a record field cannot hold a `Vec`, a `StrBuf` or a `Map` — ANSWERED: it can, since mere v0.1.456

- **State**: resolved (2026-09-09) in the language. The workaround here still stands and
  is still fine; it is no longer forced.
- **What it was**, measured at mere v0.1.447: a record with one field of each —

  | field type | v0.1.447 | v0.1.456 |
  |---|---|---|
  | `ByteBuf[R]` | works | works |
  | `Vec[R, T]` | `type error: expected &R unit, got &__heap unit` | **works** |
  | `StrBuf[R]` | same error | **works** |
  | `Map[R, K, V]` | same error | **works** |

  Re-measured against a build of the last commit before the change (`1b538a9`) and against
  HEAD, so the attribution is a measurement rather than a guess: the old binary still
  prints `expected &R unit, got &__heap unit` for the same file.
- **Why it was so, and what changed**: the field's declared region was the rigid name `R`
  and `vec_new ()` produced the rigid name `__heap`, and two rigid names do not unify. A
  function's signature can be generalised over the region and a record's field cannot, so
  the one shape a record wanted was the one shape that could not be written. `ByteBuf`
  escaped it because its region is erased from the type's tag — the exception that gave the
  cause away. mere's Q-127 work made the allocation marker a **variable until something
  decides it**, and here the field's own declaration is what decides it.
- **It did not open an escape route**, checked in both directions: a record whose field is
  typed `Vec[A, float]` and built inside `region A { }` is still refused by name when it is
  carried out (`region escape: 'sink' now holds a value from region 'A'`), and one built
  inside a block whose field names a DIFFERENT region is refused at construction
  (`expected &Rg unit, got &A unit`).
- **Asserted continuously, in the language repository**: `test/parity/record_holds_containers.mere`
  compares a record of two `Vec` fields across the interpreter, C, LLVM and Wasm on every
  parity run. That is a better home for it than a check here, because the claim is the
  language's.
- **What is still true here**: `Target` returns `(target, depth)` rather than one record.
  Collapsing it is now possible and is a readability change, not a correctness one — six
  signatures in `src/raster.mere` and `src/render.mere` take the two together. Not done,
  because the pair already cannot drift (every function takes both) and the renderer's
  gates are the expensive thing to re-run for a cosmetic gain.
- **Verify**: none — answered, and the answer is asserted by the language's own parity run
  rather than by prose here.

## Q-9: the rasterizer runs on two backends, not four

- **State**: open, and it is the language's to answer.
- `bytebuf_new`, `bytebuf_get` and `bytebuf_set` are **refused by the LLVM and Wasm
  backends** (`docs/host-matrix.md` says so, and `scripts/linalg_check.sh` prints the
  refusal rather than passing over it). So `test/raster_dump.mere` and
  `test/raster_props.mere` are compared across the interpreter and the C backend only,
  where the linear-algebra ones are compared across four.
- That is a real weakening of the strongest check this project has -- four independent
  implementations of the same arithmetic -- and it is stated in the gate's output so a
  reader is not left to assume otherwise.
- **What would fix it**: a `ByteBuf` lowering in those two backends, which is the language
  repository's work. Until then the browser path (M2c) cannot render either, since it is
  the Wasm backend.
- **Verify**: `printf "%s\n" "type box9 = { b: ByteBuf[R] };" "let x = box9 { b = bytebuf_new 8 };" "let _ = bytebuf_set x.b 0 1;" "print_int (bytebuf_get x.b 0)" > /tmp/m3dq9.mere && "$MERE" -c /tmp/m3dq9.mere >/dev/null 2>&1 && "$MERE" -ll /tmp/m3dq9.mere 2>&1 | grep -q "bytebuf_new has no LLVM lowering" && "$MERE" -w /tmp/m3dq9.mere 2>&1 | grep -q "bytebuf_new has no Wasm lowering"`
- **Why that shape**: it GREPS THE REFUSAL BY NAME rather than asserting the compiler
  fails, and it requires the C backend to accept the same program first. A bare `!
  compiles` would pass if the compiler were missing, if the flag were misspelled, or if
  the program were rejected for some unrelated reason -- reporting "still open" about a
  question it never tested.

## Q-10: a `region` does not reclaim what a function returns — ANSWERED, in three steps

- **State**: resolved (2026-09-09) on the interpreter, the C backend and the LLVM
  backend. What is left is named at the bottom and is not what this question asked.
- **What it was, and what each step changed** (every row measured, not remembered):

  | written as | v0.1.447 | now |
  |---|---|---|
  | `vec_new ()` lexically inside `region R { }` | `__region_R`, reclaimed | unchanged |
  | `bytebuf_new n` lexically inside `region R { }` | default region, **kept** | `__region_R`, **reclaimed** (v0.1.458) |
  | a container a **function returns**, called from inside the block | default region, **kept** | the caller's region, **reclaimed** (C v0.1.464, LLVM v0.1.466) |

- **The numbers this entry has carried, all three of them.** Two hundred iterations of a
  4 MB `bytebuf_new` inside a `region R { }`: **770 MB** at v0.1.447, **5.8 MB** once the
  lexical case was fixed. The same buffer built by a one-line **function**: **847 MB**,
  and now **5.5 MB**. The last one is this question.
- **How it was done, and how it was NOT done.** The region is passed IN, as a leading
  argument: a call site hands the callee whichever region it bound — a block it is
  inside, its own region parameter (which is how the outermost block reaches a body three
  calls down), or the default region where nothing decided. The other way — letting the
  callee ask what region is current at run time — was tried in mere v0.1.453 and is
  unsound for a chain of calls. **This renderer is what proved that**: it could not draw a
  second frame, in three released versions, and v0.1.456 withdrew it.
- **It did not weaken the escape check.** Carrying a callee-built container out of the
  block is still a type error, and nothing new was written to make it one: the call site
  binds the callee's region to the block, so the type follows the value and the check that
  was already there fires. mere pins the shape as `test/escape/callee_built_into_vec.mere`.
- **What is left, and it is not what this question asked**:
  - a function used as a VALUE, or applied to fewer arguments than it takes, keeps the
    default region — a closure has nowhere to carry a region. Measured across mere's 286
    examples and this renderer: **zero** such functions.
  - on LLVM, the innermost body of a curried multi-argument function is a separate
    `define` that cannot see the argument, so it keeps the default region too.
  - **this renderer's own 0.7 MB a frame is untouched, and not because of any of that.**
    The scene state (924 world matrices, the animation arrays, 84 skins' joint matrices)
    is built inside `one_frame_into` and consumed inside it, so it appears in NO enclosing
    signature — there is no type position to key a region argument on. `--dump-region-params`
    reports this program as having **zero** call sites inside a `region` block, which is
    correct: there is one block in the whole renderer (`src/view.mere`) and the frame path
    does not call a region-parameterised function from inside it. Reclaiming that state
    needs a block around the work that builds it, which is this repository's to write, not
    the language's.
- **Verify**: none — answered, and the answer is asserted continuously somewhere better
  than here: mere's `scripts/region_reclaim_check.sh` builds a container in a function,
  calls it from inside a block, and requires the footprint NOT to follow the iteration
  count, on the C and LLVM backends separately. A grep of emitted C in this file would be
  a second, weaker copy of that — and the previous version of this Verify shows why a copy
  is worse: it looked for the ABSENCE of `(&__lang_default_region)`, which an unrelated
  allocation elsewhere in the same file satisfies, so it would have gone on passing for
  the wrong reason after the question was answered.

## Q-11: a buffer is as long as its `byteLength` says, and not as long as its file

- **State**: decided (2026-09-08), recorded because it is a choice and because it made
  this reader stricter than it was.
- Every buffer is read once into one blob, and where buffer `i` starts in it is DERIVED
  by summing the `byteLength`s in front of it -- a record cannot hold a `Vec` (Q-8), so
  a table of offsets has nowhere to live and the JSON has to be the only source. That
  forces the question: a `.bin` that is longer than its `byteLength` contributes the
  declared length and no more, and the bound an accessor is checked against is the
  buffer's declared end rather than the length of the file.
- **What that changes**: a document whose bufferView runs past its buffer's
  `byteLength` is now REFUSED where it used to be read, if the file behind it happened
  to be long enough. glTF says a bufferView must fit inside its buffer, and the Khronos
  validator calls it `BUFFER_VIEW_TOO_LONG`, so the strict reading is the specified one
  -- but it is strictness this project chose for an implementation reason and would not
  otherwise have had, which is what makes it worth writing down.
- **What it caught immediately**: this repository's own normal-map property document,
  which declared 264 bytes where its four bufferViews end at 288. It had been illegal
  since TANGENT (VEC4, 96 bytes) replaced a VEC3 in it, and every reader had been
  reading past the end it declared.
- Measured across the corpus before the change: every `.bin` is exactly its
  `byteLength`, three GLBs pad their BIN chunk past it (which the specification allows),
  and no bufferView in any of the fifty documents overruns its buffer.
- **Verify**: none — a decision.

## Q-2: does `linalg` belong in the language's `contrib/`

- **State**: open. It stays here until there is a second consumer.
- The Mere project's granularity rule is that a library moves to `contrib/`
  when a second program actually imports it, not when it looks general. One
  program using it cannot tell a real generalization from a fake one.
- **Candidates for the second consumer**: a physics or collision module, an
  STL/OBJ viewer, the compiler's own benchmark suite (`mat4xvec4` currently
  writes its matrix arithmetic out by hand).
- **Verify**: none — this is a decision, not a symptom.

## Q-3: `mat4` as four `v4` columns, or as a flat buffer

- **State**: decided for now (four columns), open to revision.
- Four columns is a value type on the C and LLVM backends — a by-value struct,
  no allocation — and it reads like the mathematics: `r = c0*x + c1*y + c2*z + c3*w`.
- What might change it: the loader wants to read sixteen floats straight out of
  a glTF accessor into a matrix, and a flat `Vec[R, float]` would be a memcpy
  where this is sixteen field assignments. Whether that matters is a
  measurement nobody has taken.
- **Verify**: none — a decision.

## Q-4: where the exactness line goes when shading arrives — ANSWERED: nowhere

- **State**: resolved (2026-09-07). The line did not have to move; shading is bit-exact on
  every backend, which is not what this question assumed when it was written.
- It assumed sRGB's power of 2.4 and the GGX lobe would put `pow` on the per-pixel path
  and end the comparison. Neither does:
  - **sRGB is between a byte and a float in both directions**, so it is two tables of
    constants and a search. Decoding is 256 entries; encoding is 255 thresholds, each one
    the smallest double the `pow` reference maps to that byte, found by bisecting the
    reference so the table agrees with it by construction. `pow` is called once per entry
    at generation time and never at run time. `scripts/gen_srgb.py`.
  - **The BRDF has no transcendental in it** once Schlick's Fresnel is five multiplies
    rather than `pow(x, 5)`. Everything else is `+ - * /` and `sqrt`, which IEEE-754
    requires to be correctly rounded.
- **Measured**: `test/shade_props.mere` and `test/srgb_dump.mere` are byte-identical
  across the interpreter, C, LLVM and Wasm.
- The candidates this entry listed — a lookup table, or a plus-or-minus-one tolerance on
  pixels — were (a) and (b), and the answer is (a) alone, with (b) not needed.
- **What would still move the line**: a `pow` in a texture filter or a tone map. Neither
  exists yet, and the reason to write this down is that adding one would cost the
  four-backend comparison and should be a decision rather than a side effect.
- **Verify**: none — answered, and the answer is not left to prose: `linalg_check.sh`
  compares `shade_props` and `srgb_dump` across all four backends on every run, so the
  claim that shading is bit-exact is asserted continuously rather than remembered.

## Q-5: `V3.normalize` of a zero vector returns zero

- **State**: decided, recorded because it is a choice and not a law.
- A degenerate triangle has a zero normal. Returning a NaN would be the
  arithmetic's answer, and a NaN spreads silently into every pixel it touches;
  a zero is visible and local. The same reasoning applies to
  `V4.perspective_divide` at w = 0, which returns the point unprojected rather
  than three infinities, and leaves clipping to the caller.
- What would change it: a caller that needs to distinguish "no direction" from
  "the zero direction". None exists yet.
- **Verify**: none — a decision.
