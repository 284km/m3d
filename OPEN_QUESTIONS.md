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

## Q-8: a record field cannot hold a `Vec`, a `StrBuf` or a `Map`

- **State**: open in the language; worked around here, and the workaround is fine.
- **Measured** (mere v0.1.447), a record with one field of each:

  | field type | result |
  |---|---|
  | `ByteBuf[R]` | **works** |
  | `Vec[R, T]` | `type error: expected &R unit, got &__heap unit` |
  | `StrBuf[R]` | same |
  | `Map[R, K, V]` | same |

  A tuple holding a `Vec` works, and so does a function taking or returning one -- a
  function's signature can be generalised over the region and a record's field cannot.
  `ByteBuf` escapes it because its region is erased from the type's tag.
- **Why it showed up here**: a framebuffer wants a colour buffer AND a depth buffer, and
  depth has to be floats. `contrib/raster`'s canvas gets away with one field because that
  field is a `ByteBuf`.
- **The workaround, and why it is not a bad one**: `Target.make` returns the pair, and
  every function takes the two together, so they cannot end up different sizes. It reads
  worse than one record and is otherwise the same program.
- **The alternative that was rejected**: keeping depth as f32 bit patterns inside a second
  `ByteBuf`, which would fit in the record. It costs four `bytebuf_get` plus a shift and a
  widening per depth test, in the innermost loop of the rasterizer, to buy a nicer type.
- **Verify**: `printf "%s\n" "type ok8 = { v: int };" "let a = ok8 { v = 1 };" "print_int a.v" > /tmp/m3dq8ctl.mere && "$MERE" /tmp/m3dq8ctl.mere >/dev/null 2>&1 && printf "%s\n" "type box8 = { v: Vec[R, float] };" "let b = box8 { v = vec_new () };" "print_int (vec_len b.v)" > /tmp/m3dq8.mere && "$MERE" /tmp/m3dq8.mere 2>&1 | grep -q "__heap"`
- **The previous version of this check was VACUOUS**, and building `questions_check.sh`
  found it. It wrote the program with `printf '...\{...'`, where `\{` is not an escape
  any printf here expands -- so the file contained a literal backslash, `mere` answered
  `parse error: expected type`, and the check (a bare `! mere file`) passed because the
  program did not parse rather than because a record cannot hold a `Vec`. The claim was
  still true; nothing had been testing it. This version writes the braces as ARGUMENTS
  rather than inside the format string, requires a plain-`int` record to run first as a
  positive control, and GREPS THE ERROR by name (`__heap`) instead of negating.

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

## Q-10: a `region` does not reclaim a `ByteBuf`, so a frame loop cannot lean on one

- **State**: open in the language; worked around here, twice, and the workaround costs
  something both times.
- **Measured** (mere v0.1.447): two hundred iterations of a 4 MB `bytebuf_new` INSIDE a
  `region R { }` reach 770 MB of peak RSS, against 5 MB for one iteration. Nothing is
  freed at the end of the block.
- **Why**: a container whose region marker is `__heap` is allocated from the DEFAULT
  region, and the default region is never freed. The emitted C says so directly -- a
  `bytebuf_new` written *inside* the block still comes out as
  `mere_bytebuf_new((&__lang_default_region), ...)` -- so this is not about escape
  analysis or about the value outliving the block. It cannot outlive it; it is simply
  not allocated where the block can free it.
- **AND THE RULE IS NARROWER THAN "A REGION DOES NOTHING", which is worth stating
  because the wide version is the one a reader would take away.** Read out of the
  emitted C:

  | written as | allocated from | reclaimed by the block |
  |---|---|---|
  | `vec_new ()` lexically inside `region R { }` | `__region_R` | **yes** |
  | `read_bytes path` (anywhere) | `__lang_current_region` | **yes** |
  | a `Vec` or `ByteBuf` returned by a FUNCTION | `(&__lang_default_region)` | no |

  `Acc.floats` is the third row -- `mere_vec_float_new((&__lang_default_region))` -- and
  that one line is the renderer's whole remaining per-frame growth: the vertex data,
  decoded again every frame into a region nothing frees. A function's return type is
  generalised over the region, `__heap` is what it generalises to, and the lowering
  reads `__heap` as the default region rather than as the caller's.
- **What it cost here**: the render target is allocated once and cleared per frame
  rather than made per frame (`one_frame_into` takes a target), and the decoded textures
  live in a cache the caller owns rather than in the frame's region. Both are what a
  renderer would do anyway, which is why neither is a hardship -- but neither is a
  choice, and a reader would otherwise assume the `region` around a frame was doing the
  work.
- **What would answer it**: a lowering that gives `__heap` containers the current region
  in non-lib mode, in the language repository. Until then a `region` block reclaims the
  small values and none of the buffers.
- **Verify**: `printf '%s\n' 'let one = fn (i: int) -> region R { let b = bytebuf_new 16 in bytebuf_get b 0 };' 'let _ = print (str_of_int (one 0));' '0' > /tmp/m3dq10.mere && "$MERE" -c /tmp/m3dq10.mere > /tmp/m3dq10.c 2>/dev/null && grep -q '__lang_region_block_acquire("region R")' /tmp/m3dq10.c && grep -q 'mere_bytebuf_new((&__lang_default_region)' /tmp/m3dq10.c`
- **Why that shape**: the first grep is a POSITIVE CONTROL -- it requires the region
  block to have been emitted at all, so a compiler that stopped emitting regions (or a
  probe the optimiser deleted) fails rather than reporting the question answered. The
  second is the claim itself, by name. Both greps are of the emitted C rather than of a
  peak-RSS measurement, which is quantised, machine-dependent, and would make this gate
  flaky for no gain.

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
