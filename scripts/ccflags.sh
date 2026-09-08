#!/bin/sh
# scripts/ccflags.sh — how this repository compiles the C that `mere -c` emits.
#
# SOURCED by every gate that compiles, and written once rather than six times: a rule
# copied into six scripts becomes six rules, and this one was wrong in all of them for
# the whole life of the project without a single local run noticing.
#
# WHY THERE IS A FLAG AT ALL -- AND WHY IT IS NOW A GUARD RATHER THAN A REQUIREMENT.
#
# Mere used to emit a chain of `let`s as one statement expression per binding, nested --
# `({ a; ({ b; ({ c; ... }) }) })` -- so the bracket nesting of the emitted `main()` grew
# with the number of bindings in the program AND in everything it imports. This
# repository is where that was found, and mere v0.1.449 fixed it: the chain now collects
# into a single statement expression, and m3d's emitted C compiles on Ubuntu's clang 18
# WITH NO FLAG, where before it failed at the first gate of every CI run this project
# ever had.
#
# The flag stays because the shape can come back from a direction this fix did not
# touch: any right-nested chain -- a long list literal, a long `++` -- still nests one
# level per element, and mere-ruby is still over the limit for exactly that reason. A
# guard that costs nothing against a failure that is invisible on the machine this is
# developed on.
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
