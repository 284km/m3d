#!/bin/sh
# scripts/questions_check.sh — hold OPEN_QUESTIONS.md to the same standard as the code.
#
# Every entry there claims something is still true. Nothing was checking that. A question
# whose symptom somebody fixed, or whose absent feature somebody added, goes on reading
# as open forever, and the file quietly becomes a list of things that USED to be so.
#
# Each entry carries one line:
#
#   - **Verify**: `<command>`     exit 0 while the question is STILL OPEN. A non-zero
#                                 exit is a RETIRE candidate, not a pass.
#   - **Verify**: none — <why>    a decision rather than a symptom. Counted, not run.
#
# EVERY QUESTION MUST CARRY ONE. A question with no Verify line at all is the failure
# this gate was written for: Q-9 ("the rasterizer runs on two backends") had none, and a
# symptom with no check is indistinguishable from a symptom nobody has looked at since.
#
# THE NEGATED CHECKS ARE THE DANGEROUS ONES, and most of these are negated -- they assert
# a feature is still ABSENT, in the form `! mere -te 'some_name'`. A negation succeeds
# when the thing it negates fails FOR ANY REASON: no compiler, a typo in the flag, an
# unset variable. Then the gate reports "still open" about a question it never tested,
# which is the reassuring answer a broken check gives. So before running anything, this
# establishes POSITIVE CONTROLS: the same mechanisms are pointed at something that
# certainly exists and must find it. If a control fails the run SKIPS BY NAME rather
# than reporting green.
#
# Usage:  MERE=/path/to/mere.exe MERE_SRC=/path/to/mere sh scripts/questions_check.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-mere}"
command -v "$MERE" >/dev/null 2>&1 || { echo "questions: no mere — set MERE=..." >&2; exit 1; }
cd "$ROOT"
Q="OPEN_QUESTIONS.md"
[ -f "$Q" ] || { echo "questions: no $Q"; exit 1; }

# --- positive controls -------------------------------------------------------
# `-te` must FIND a name that exists. If it cannot, every `! ... -te ...` below is
# vacuously true and the whole run means nothing.
if ! "$MERE" -te 'vec_new' >/dev/null 2>&1; then
  echo "questions: SKIP — '$MERE -te vec_new' does not find a builtin that certainly"
  echo "questions: exists, so the negated checks would all pass without testing anything"
  exit 0
fi
# The same for the path checks: MERE_SRC must name a real checkout, or
# `! ls \"\$MERE_SRC/contrib/...\"` is true because the whole tree is missing.
if [ -n "${MERE_SRC:-}" ]; then
  [ -d "$MERE_SRC/contrib" ] || {
    echo "questions: SKIP — MERE_SRC is set to '$MERE_SRC', which has no contrib/,"
    echo "questions: so a check for an absent file there cannot tell absent from wrong path"
    exit 0; }
else
  echo "questions: SKIP — MERE_SRC is unset, and a check for an absent file under it"
  echo "questions: would pass because the whole tree is missing"
  exit 0
fi
export MERE MERE_SRC

# --- run ---------------------------------------------------------------------
open=0; decisions=0; retire=0; missing=0
qs=$(grep -c '^## Q-' "$Q")
[ "$qs" -gt 0 ] || { echo "questions: no questions found in $Q, so this gate is vacuous"; exit 1; }

# One pass, remembering the heading each Verify belongs to, so a Verify that has drifted
# away from its question is attributed to the right one.
cur=""; seen=""
while IFS= read -r line; do
  case "$line" in
    '## Q-'*)
      # The previous question ended. Did it carry a Verify?
      if [ -n "$cur" ] && ! printf '%s' "$seen" | grep -q "|$cur|"; then
        echo "  $cur has NO **Verify** line — a claim with nothing checking it"
        missing=$((missing + 1))
      fi
      cur=$(printf '%s' "$line" | sed 's/^## //; s/:.*//')
      ;;
    '- **Verify**: '*)
      seen="$seen|$cur|"
      body=${line#- \*\*Verify\*\*: }
      case "$body" in
        none*|None*)
          decisions=$((decisions + 1)) ;;
        '`'*)
          cmd=$(printf '%s' "$body" | sed 's/^`//; s/`[^`]*$//')
          if eval "$cmd" >/dev/null 2>&1; then
            open=$((open + 1))
          else
            echo "  $cur: its Verify no longer holds — RETIRE candidate"
            echo "      $cmd"
            retire=$((retire + 1))
          fi ;;
        *)
          echo "  $cur: its Verify is neither a backquoted command nor 'none'"
          missing=$((missing + 1)) ;;
      esac ;;
  esac
done < "$Q"
if [ -n "$cur" ] && ! printf '%s' "$seen" | grep -q "|$cur|"; then
  echo "  $cur has NO **Verify** line — a claim with nothing checking it"
  missing=$((missing + 1))
fi

echo "questions: $qs question(s) — $open still reproduce, $decisions are decisions"
if [ "$((open + decisions))" -eq 0 ]; then
  echo "questions: nothing was actually checked, so this gate is vacuous"; exit 1
fi
[ "$missing" -eq 0 ] || { echo "questions: $missing question(s) carry no usable Verify"; exit 1; }
[ "$retire" -eq 0 ] || { echo "questions: $retire question(s) may be retired"; exit 1; }
echo "questions: ok"
