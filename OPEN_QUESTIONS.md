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

## Q-4: where the exactness line goes when shading arrives

- **State**: open, and the first thing M1c will have to settle.
- Today the line is clean: everything a glTF file needs uses only the five
  correctly-rounded operations, and the trigonometry is fenced off. Shading
  breaks that — sRGB encoding is `pow(x, 1/2.4)` and the GGX distribution is
  full of it — so the pixel path cannot be bit-exact across backends.
- **Candidates**: (a) a 256-entry sRGB lookup table, so `pow` is called at
  table-build time and the per-pixel path stays exact; (b) accept a
  quantized-plus-or-minus-one tolerance on pixels and keep bit-exactness for
  geometry only; (c) both, which is probably the answer.
- **Verify**: none yet — there is no shading code to ask.

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
