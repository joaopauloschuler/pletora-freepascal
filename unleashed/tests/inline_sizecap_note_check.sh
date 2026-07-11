#!/usr/bin/env bash
# checknodeinlining refusal (f): the node-count / heuristics_favors_inlining
# size cap used to refuse an over-budget `inline` routine SILENTLY -- the
# call-site note just said "...is not inlined" with no clue how big the body
# was or what the budget is.  It now spells out BOTH numbers:
#
#   Note: Call to subroutine "..." marked as inline is not inlined
#         (body node count N exceeds inlining budget B)
#
# (tcallnode.inline_size_over_budget in compiler/ncal.pas measures the whole
# retained body and the effective budget -- both a function of inlinelevel --
# and optcall.doinline appends them to the cg_n_no_inline note.)
#
# This asserts:
#   Part A: an over-budget inline routine's note contains BOTH the measured
#           node count and the budget, and count > budget.
#   Part B: a small inline routine inlines (no such note; no call at -O2) --
#           the size-cap note is not a false positive.
#
# Usage: unleashed/tests/inline_sizecap_note_check.sh [path-to-ppcx64]
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

rc=0
fail() { echo "FAIL: $*"; rc=1; }
run() { ulimit -v 4000000; timeout 200 "$@"; }

# ---------------------------------------------------------------------------
# Part A: over-budget routine -> note carries both numbers
# ---------------------------------------------------------------------------
{
  echo '{$mode objfpc}'
  echo 'program big;'
  echo 'function bigfn(x: longint): longint; inline;'
  echo 'begin'
  echo '  bigfn := x;'
  for ((i=0; i<3000; i++)); do
    echo "  bigfn := bigfn + $((i%7)) - $((i%3)) + (x xor $((i%5)));"
  done
  echo 'end;'
  echo 'begin'
  echo '  writeln(bigfn(10));'
  echo 'end.'
} > "$tmp/big.pp"

note="$(run "$CC" -Fu"$RTL" -O2 -vn -FE"$tmp" "$tmp/big.pp" 2>&1 | grep -iE 'is not inlined')"
if [ -z "$note" ]; then
  fail "Part A: no 'is not inlined' note for the over-budget routine"
else
  echo "$note" | grep -qiE 'body node count [0-9]+ exceeds inlining budget [0-9]+' \
    || fail "Part A: note lacks both numbers: [$note]"
  cnt="$(echo "$note" | sed -nE 's/.*body node count ([0-9]+) exceeds inlining budget ([0-9]+).*/\1/p')"
  bud="$(echo "$note" | sed -nE 's/.*body node count ([0-9]+) exceeds inlining budget ([0-9]+).*/\2/p')"
  if [ -n "$cnt" ] && [ -n "$bud" ]; then
    [ "$cnt" -gt "$bud" ] || fail "Part A: measured count ($cnt) not > budget ($bud)"
  else
    fail "Part A: could not extract count/budget from note: [$note]"
  fi
fi
# it must still run correctly (out of line)
if run "$CC" -Fu"$RTL" -O2 -FE"$tmp" "$tmp/big.pp" >/dev/null 2>&1; then
  out="$(run "$tmp/big" 2>&1)"
  # bigfn(10)=10 + sum over i of ((i%7)-(i%3)+(10 xor (i%5)))
  exp="$(python3 -c 'print(10+sum((i%7)-(i%3)+(10^(i%5)) for i in range(3000)))' 2>/dev/null)"
  if [ -n "$exp" ]; then
    [ "$out" = "$exp" ] || fail "Part A: wrong runtime output [$out] (expected $exp)"
  fi
else
  fail "Part A: compile/link of big.pp failed"
fi

# ---------------------------------------------------------------------------
# Part B: small routine inlines -> no size-cap note, no call at -O2
# ---------------------------------------------------------------------------
cat > "$tmp/small.pp" <<'EOF'
{$mode objfpc}
program small;
function tinyfn(x: longint): longint; inline;
begin
  tinyfn := x * 3 + 1;
end;
begin
  writeln(tinyfn(7));
end.
EOF
notesmall="$(run "$CC" -Fu"$RTL" -O2 -vn -al -FE"$tmp" "$tmp/small.pp" 2>&1 | grep -iE 'exceeds inlining budget')"
[ -z "$notesmall" ] || fail "Part B: small routine wrongly got a size-cap note: [$notesmall]"
if grep -Eq 'call[[:space:]].*_\$\$_TINYFN' "$tmp/small.s"; then
  fail "Part B: tinyfn was NOT inlined at -O2 (call present)"
fi
out="$(run "$tmp/small" 2>&1)"
[ "$out" = "22" ] || fail "Part B: wrong output [$out] (expected 22)"

if [ "$rc" -eq 0 ]; then
  echo "PASS: over-budget inline routine's note reports both body node count and inlining budget (count>budget); small routine still inlines with no false-positive note"
fi
exit "$rc"
