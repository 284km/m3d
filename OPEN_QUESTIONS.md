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

## Q-10: a `region` reclaims what is written inside it, and not what a function returns

- **State**: **half of it was answered** by mere v0.1.456 (2026-09-09); the half that costs
  this renderer anything is still open, and the language now knows why it is hard.
- **What the block reclaims, re-measured at v0.1.456** (read out of the emitted C, and
  confirmed by peak RSS):

  | written as | allocated from | reclaimed by the block |
  |---|---|---|
  | `vec_new ()` lexically inside `region R { }` | `__region_R` | **yes** (always was) |
  | `bytebuf_new n` lexically inside `region R { }` | `__region_R` | **yes — this is the change** |
  | `read_bytes path` (anywhere) | `__lang_current_region` | **yes** (always was) |
  | a `Vec` or `ByteBuf` **returned by a function** | `(&__lang_default_region)` | **no** |

- **The number that used to be in this entry has moved.** Two hundred iterations of a 4 MB
  `bytebuf_new` inside a `region R { }` reached **770 MB** of peak RSS at v0.1.447. At
  v0.1.456 the same program is **5.8 MB**. Writing the same loop with the buffer built by a
  one-line FUNCTION called from inside the block reaches **847 MB** — so the meter still
  works, the difference is the last row of the table, and it is the only row left.
- **Why the last row cannot simply be flipped, which is the part that is now known.** mere
  tried exactly that in v0.1.453: settle an undecided region on the caller's, which the
  backends lower to the runtime current region. It shipped, and **this renderer was the
  witness that killed it** — a segfault from the second frame on, in v0.1.453, 454 and 455.
  A body and its call site hold **different copies** of the region variable, and in a chain
  (`render_at` → `one_frame_into` → `attr` → `Acache.floats` → `Acc.floats`) only the
  outermost copy is bound by the block. The innermost body allocates through the scheme's
  own variable, which nothing bound; lowered to the runtime current region, the value went
  into the frame's arena while every type said the default one, and the accessor cache read
  it back after the arena was reused. Withdrawn in v0.1.456.
  **`dune runtest`, parity, every gate and all 29 dogfood type-checks were green** while
  three released versions could not render a second frame here.
- **So the remaining answer is one of two, and both are bigger than a lowering change**:
  pass the region in as a hidden argument, or specialise a function per region. mere's
  Q-127 measured that region **cannot** be a monomorphization axis in the C backend — the
  region is not part of the C type (`Vec[R,T]` and `Vec[__heap,T]` are both
  `mere_vec_<T>*`), so duplicating instances cannot distinguish them.
- **What survives the withdrawal, and it is not nothing**: the TYPES still name the block,
  so carrying a callee-built container out of a `region` is a type error now. Being typed
  to a region the value does not actually live in is over-strict and never unsound, which
  is the direction it errs in.
- **What it costs here**: unchanged. The render target is allocated once and cleared per
  frame rather than made per frame, and decoded textures and accessors live in caches the
  caller owns. The **0.7 MB/frame** that neither cache can remove — 924 world matrices, the
  animation's seven arrays, 84 skins' joint matrices, all different every frame — is the
  last row of that table and nothing else.
- **The accessor cache is no longer "code that would be rejected".** The previous version of
  this entry said the real fix would make `Acache` a type error and force it into a warm
  pass. That prediction was about the design mere has now withdrawn; under either remaining
  candidate the cache is ordinary code, because a container the caller allocates and a
  callee fills is exactly what passing the region in expresses.
- **Verify**: `printf '%s\n' 'let mk = fn (n: int) -> bytebuf_new 16;' 'let one = fn (i: int) -> region R { let b = mk i in bytebuf_get b 0 };' 'let two = fn (i: int) -> region S { let b = bytebuf_new 16 in bytebuf_get b 0 };' 'let _ = print (str_of_int (one 0 + two 0));' '0' > /tmp/m3dq10.mere && "$MERE" -c /tmp/m3dq10.mere > /tmp/m3dq10.c 2>/dev/null && grep -q 'mere_bytebuf_new(__region_S' /tmp/m3dq10.c && grep -q 'mere_bytebuf_new((&__lang_default_region)' /tmp/m3dq10.c`
- **Why that shape**: the entry now claims TWO things, and the check asserts both. The first
  grep is the answered half used as a positive control — a buffer written lexically inside a
  block must come out as `__region_S`, so a compiler that stopped emitting regions, or one
  that regressed to the v0.1.447 behaviour, fails here instead of reporting the remaining
  half open. The second grep is the remaining claim, by name. Both are of the emitted C
  rather than of a peak-RSS measurement, which is quantised, machine-dependent, and would
  make this gate flaky for no gain. **Both greps were run against a build of `1b538a9`**, the
  last commit before the change: the control grep finds nothing there and the check exits
  non-zero, so it is a live control and not a decoration. That is the correct answer for an
  older compiler — this entry describes v0.1.456 and would need rewriting for any tree where
  the control does not hold.

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
