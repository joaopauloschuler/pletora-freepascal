#!/usr/bin/env bash
# Firing / soundness checks for -OoUNROLLJAM (unroll-and-jam, gated in -O4).
#
# The pass unrolls the outer loop of a two-level counted nest by K=4 and jams
# the K duplicated inner-loop bodies into ONE inner loop, driven by a SINGLE
# copy of the inner bound.  That is sound only when the inner bound is invariant
# across the K consecutive outer iterations it collapses.  This script asserts:
#
#   Part A (firing): on a CLASSIC RECTANGULAR nest (constant / outer-invariant
#     inner bound) the pass fires -- the compiler prints the "-vn" note
#     "Two-level loop nest unroll-and-jammed".
#
#   Part B (refusal): on a nest whose inner bound DEPENDS ON THE OUTER COUNTER
#     (an array element rowlen[i], the shape of the self-host blocker #6
#     miscompile) the pass MUST decline -- it prints "Loop nest not
#     unroll-and-jammed: inner loop bounds are not invariant ..." and does NOT
#     print the "unroll-and-jammed" note.  Jamming it would drive K
#     different-length inner bodies with one wrong bound (out-of-bounds stores).
#
#   Part C (semantics): the promoted regression test compiles and runs cleanly
#     at -O4 (declined) and at -O4 -OoNOUNROLLJAM, byte-identical stdout, exit 0.
#
# Usage: unleashed/tests/unrolljam_check.sh [path-to-ppcx64]
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

rc=0
fail() { echo "FAIL: $*"; rc=1; }

FIRED='Two-level loop nest unroll-and-jammed'
DECLINED='Loop nest not unroll-and-jammed'

# ---------------------------------------------------------------------------
# Part A: fires on a rectangular nest (constant / outer-invariant inner bound)
# ---------------------------------------------------------------------------
cat > "$tmp/rect.pp" <<'EOF'
{$mode objfpc}
const N=200; M=64;
var a:array[0..N-1,0..M-1] of int64; b:array[0..M-1] of int64; c:array[0..N-1] of int64;
procedure mm(n,m:longint);
var i,j:longint; s:int64;
begin
  for i:=0 to n-1 do begin s:=0; for j:=0 to m-1 do s:=s+a[i,j]*b[j]; c[i]:=s; end;
end;
begin mm(N,M); writeln(c[0]); end.
EOF
rect_log="$("$CC" -Fu"$RTL" -O4 -vn "$tmp/rect.pp" 2>&1)"
if echo "$rect_log" | grep -q "$FIRED"; then
  echo "A rectangular nest: FIRED (unroll-and-jammed)"
else
  fail "rectangular nest was NOT unroll-and-jammed (pass stopped firing)"
  echo "$rect_log" | grep -i unroll || true
fi

# ---------------------------------------------------------------------------
# Part B: refused on an outer-dependent inner bound (rowlen[i])
# ---------------------------------------------------------------------------
cat > "$tmp/vary.pp" <<'EOF'
{$mode objfpc}
const P=8;
var rowlen:array[1..P] of longint; a:array[1..P,0..15] of int64;
procedure ResetLike;
var i,j:longint; v:int64;
begin
  for i:=1 to P do
    for j:=0 to rowlen[i]-1 do
      begin v:=a[i,j]; v:=v+1; a[i,j]:=v; end;
end;
begin ResetLike; writeln(a[1,0]); end.
EOF
vary_log="$("$CC" -Fu"$RTL" -O4 -vn "$tmp/vary.pp" 2>&1)"
if echo "$vary_log" | grep -q "$FIRED"; then
  fail "outer-dependent inner bound was unroll-and-jammed (unsound: blocker #6)"
  echo "$vary_log" | grep -i unroll || true
elif echo "$vary_log" | grep -q "inner loop bounds are not invariant"; then
  echo "B outer-dependent bound: DECLINED (bounds not invariant)"
else
  fail "outer-dependent nest neither jammed nor declined for the expected reason"
  echo "$vary_log" | grep -i "$DECLINED" || true
fi

# ---------------------------------------------------------------------------
# Part C: promoted regression test -- correct at -O4 and -O4 -OoNOUNROLLJAM
# ---------------------------------------------------------------------------
reg="$here/testfiles/optunrolljam/unrolljam_varying_inner_bound_01.pp"
if [ -f "$reg" ]; then
  d="$tmp/reg"; mkdir -p "$d/on" "$d/off"; cp "$reg" "$d/on/"; cp "$reg" "$d/off/"
  name="$(basename "$reg" .pp)"
  ( cd "$d/on"  && "$CC" -Fu"$RTL" -O4                -o"$d/on/e"  "$name.pp" >/dev/null 2>&1 )
  ( cd "$d/off" && "$CC" -Fu"$RTL" -O4 -OoNOUNROLLJAM -o"$d/off/e" "$name.pp" >/dev/null 2>&1 )
  if [ ! -x "$d/on/e" ]; then fail "regression test did not compile at -O4"
  elif [ ! -x "$d/off/e" ]; then fail "regression test did not compile at -O4 -OoNOUNROLLJAM"
  else
    out_on="$( (ulimit -v 3000000; timeout 60 "$d/on/e");  echo "exit=$?")"
    out_off="$( (ulimit -v 3000000; timeout 60 "$d/off/e"); echo "exit=$?")"
    if [ "$out_on" != "$out_off" ]; then
      fail "regression -O4 vs -OoNOUNROLLJAM output differ (ON:$out_on OFF:$out_off)"
    elif [[ "$out_on" != *"exit=0"* ]]; then
      fail "regression test nonzero exit ($out_on)"
    else
      echo "C regression test: identical, $out_on"
    fi
  fi
else
  fail "regression test missing: $reg"
fi

[ "$rc" -eq 0 ] && echo "PASS: unroll-and-jam fires on rectangular nests, refuses outer-dependent inner bounds"
exit "$rc"
