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
