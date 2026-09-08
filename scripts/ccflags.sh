#!/bin/sh
# scripts/ccflags.sh — how this repository compiles the C that `mere -c` emits.
#
# SOURCED by every gate that compiles, and written once rather than six times: a rule
# copied into six scripts becomes six rules, and this one was wrong in all of them for
# the whole life of the project without a single local run noticing.
#
# WHY THERE IS A FLAG AT ALL. Mere emits a program's top-level `let`s as ONE nested
# statement expression -- `({ a; ({ b; ({ c; ... }) }) })` -- so the bracket nesting of
# the emitted `main()` grows with the number of bindings in the program AND in
# everything it imports. Measured: about two levels per binding (a file of 300 trivial
# top-level lets emits a depth of 609), and m3d's own `main()` sits at 533.
#
# Clang's default limit is 256. Ubuntu's clang 18 enforces it and Apple's clang does
# not, so `clang -O2 -w m3d.c` builds on a Mac and fails on a Linux runner with
#
#     fatal error: bracket nesting level exceeded maximum of 256
#
# THAT IS WHY EVERY CI RUN SINCE THE SECOND COMMIT WAS RED while every local run was
# green -- and because check.sh stops at the first gate, the red said nothing about the
# nine gates behind it. A red CI is one failure plus everything downstream unknown.
#
# The limit is reproducible on a Mac with `-fbracket-depth=256`, which is what makes
# this checkable without a Linux machine.
#
# gcc has no such limit and does not know the flag, so the flag is added only when the
# compiler ACCEPTS it -- probed by compiling, not by asking for a version string.
CC="${CC:-clang}"
CFLAGS_M3D="-O2 -w"
if command -v "$CC" >/dev/null 2>&1 \
   && echo 'int main(void){return 0;}' \
      | "$CC" -x c -fbracket-depth=4096 -fsyntax-only - >/dev/null 2>&1; then
  # 4096 against a measured 533: the headroom is deliberate, because the depth grows
  # with the program and the failure it prevents is invisible on the machine this is
  # usually developed on.
  CFLAGS_M3D="$CFLAGS_M3D -fbracket-depth=4096"
fi
