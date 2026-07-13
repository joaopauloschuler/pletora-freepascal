#!/usr/bin/env bash
# Codegen/remark assertion for the -OoPURE loop-pass fence relaxation.
#
# The loop-family passes in optloop.pas used to treat ANY call in/around a loop
# as a hard barrier or disqualifier. With -OoPURE two of them now relax that for
# a resolved DIRECT call to a proven-attribute target:
#
#   * -OoREASSOC    : a reduction addend  acc := acc + f(a[i])  whose f is proven
#                     CONST or PURE is duplicated with a shifted counter into K
#                     partial accumulators (the reduction body's only store is a
#                     non-address-taken local accumulator, so a PURE global-reading
#                     callee is transparent too).
#   * -OoSTOREMOTION: a loop whose body contains a proven-CONST call may still have
#                     an invariant-address global promoted to a register (a const
#                     call reads/writes no memory). PURE is NOT enough here (a pure
#                     callee could read the promoted global's stale memory copy).
#
# The transforms emit -OoREPORT remarks (diagnostic only -- they never change the
# generated assembly). This script proves each fires with -OoPURE, is correctly
# gated (does NOT fire without it), and stays conservative for impure/indirect
# targets. Runtime correctness is proven by the matching testfiles fixtures
# (optreassoc/reassoc_purecall_01.pp, optstoremotion/optstoremotion_purecall_01.pp).
#
# Usage: unleashed/tests/pure_loop_check.sh [path-to-ppcx64]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ---- REASSOC kernel: const, pure and impure/indirect addends ---------------
cat > "$tmp/r.pp" <<'EOF'
program r;
{$mode objfpc}
var gf: longint = 3; side: longint = 0;
type tfn = function(x: longint): longint;
function sq(x: longint): longint; noinline; begin sq := x*x; end;
function scaled(x: longint): longint; noinline; begin scaled := x*gf; end;
function bumps(x: longint): longint; noinline; begin side := side+1; bumps := x; end;
function r_const(const a: array of longint): longint; noinline;
var i,s: longint; begin s:=0; for i:=0 to high(a) do s:=s+sq(a[i]); r_const:=s; end;
function r_pure(const a: array of longint): longint; noinline;
var i,s: longint; begin s:=0; for i:=0 to high(a) do s:=s+scaled(a[i]); r_pure:=s; end;
function r_impure(const a: array of longint): longint; noinline;
var i,s: longint; begin s:=0; for i:=0 to high(a) do s:=s+bumps(a[i]); r_impure:=s; end;
function r_indirect(const a: array of longint; f: tfn): longint; noinline;
var i,s: longint; begin s:=0; for i:=0 to high(a) do s:=s+f(a[i]); r_indirect:=s; end;
var a: array of longint; i: longint;
begin SetLength(a,50); for i:=0 to 49 do a[i]:=i;
  writeln(r_const(a)+r_pure(a)+r_impure(a)+r_indirect(a,@sq)); end.
EOF

# ---- STOREMOTION kernel: const vs pure vs impure call in the loop ----------
cat > "$tmp/s.pp" <<'EOF'
program s;
{$mode objfpc}
var g: longint; seen: longint = 0;
function sq(x: longint): longint; noinline; begin sq := x*x; end;
function preads(x: longint): longint; noinline; begin preads := seen + x; end;
function impure(x: longint): longint; noinline; begin seen := seen+x; impure := x; end;
procedure sm_const(n: longint); noinline;
var i: longint; begin for i:=1 to n do g := g + sq(i); end;
procedure sm_pure(n: longint); noinline;
var i: longint; begin for i:=1 to n do g := g + preads(i); end;
procedure sm_impure(n: longint); noinline;
var i: longint; begin for i:=1 to n do g := g + impure(i); end;
begin g:=0; sm_const(10); sm_pure(10); sm_impure(10); writeln(g); end.
EOF

rc=0

# ===== REASSOC =====
r_on="$( "$CC" -Fu"$RTL" -O4 -OoPURE -OoREASSOC -OoREPORT "$tmp/r.pp" -FE"$tmp" 2>&1 || true )"
r_off="$( "$CC" -Fu"$RTL" -O4 -OoREASSOC -OoREPORT "$tmp/r.pp" -FE"$tmp" 2>&1 || true )"

echo "--- reassoc remarks with -OoPURE ---"
grep -E 'reassoc: (reduction|not)' <<<"$r_on" || true

# with -OoPURE: the const- and pure-addend reductions are split (mention the call)
n_split_call=$(grep -cE 'reassoc: reduction loop split .* proven pure/const call' <<<"$r_on" || true)
# impure/indirect addends must still decline
n_decline_on=$(grep -cE 'reassoc: not reassociated: .*contains a call/non-pure intrinsic' <<<"$r_on" || true)
# without -OoPURE: NO reduction is split at all
n_split_off=$(grep -cE 'reassoc: reduction loop split' <<<"$r_off" || true)

echo "with -OoPURE:  split-with-call remarks = $n_split_call (expect 2: const + pure addend)"
echo "with -OoPURE:  declined-call  remarks = $n_decline_on (expect 2: impure + indirect)"
echo "without -OoPURE: any split remarks    = $n_split_off (expect 0)"

[ "$n_split_call" = "2" ] || { echo "FAIL: reassoc did not admit both a const and a pure addend call under -OoPURE"; rc=1; }
[ "$n_decline_on" -ge 2 ] || { echo "FAIL: reassoc wrongly admitted an impure or indirect addend call"; rc=1; }
[ "$n_split_off" = "0" ]  || { echo "FAIL: reassoc split a call-bearing reduction without -OoPURE"; rc=1; }

# ===== STOREMOTION =====
s_on="$( "$CC" -Fu"$RTL" -O4 -OoPURE -OoSTOREMOTION -OoREPORT "$tmp/s.pp" -FE"$tmp" 2>&1 || true )"
s_off="$( "$CC" -Fu"$RTL" -O4 -OoSTOREMOTION -OoREPORT "$tmp/s.pp" -FE"$tmp" 2>&1 || true )"

echo "--- storemotion remarks with -OoPURE ---"
grep -E 'storemotion: promoted' <<<"$s_on" || true

# exactly one loop (the const-call one) is promoted with a const call in the body
n_sm_const=$(grep -cE 'storemotion: promoted .* not to touch global memory' <<<"$s_on" || true)
# without -OoPURE nothing is promoted (every loop has a call)
n_sm_off=$(grep -cE 'storemotion: promoted' <<<"$s_off" || true)

echo "with -OoPURE:  const-call promotions = $n_sm_const (expect 1)"
echo "without -OoPURE: any promotions       = $n_sm_off (expect 0)"

[ "$n_sm_const" = "1" ] || { echo "FAIL: storemotion did not promote across a const call under -OoPURE (or promoted the pure/impure loops)"; rc=1; }
[ "$n_sm_off" = "0" ]   || { echo "FAIL: storemotion promoted a call-bearing loop without -OoPURE"; rc=1; }

[ "$rc" -eq 0 ] && echo "PASS: -OoPURE relaxes the reassoc and storemotion loop-pass call fences, correctly gated"
exit "$rc"
