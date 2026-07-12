#!/usr/bin/env bash
# Codegen / diagnostic assertion for the -OoLOOPINTERCHANGE loop-interchange pass:
# a perfect two-deep counted for-nest whose inner loop strides a non-contiguous
# flat 2D index  a[i*W+j]  is reordered so the inner loop strides the contiguous
# dimension, exposing it to the vectorizer.
#
# The transform fires only under the opt-in switch and only when the interchanged
# order is strictly more cache-contiguous (a cost model on the affine subscript
# coefficients), and it refuses unsafe / non-matching shapes.  We assert on the
# -OoREPORT optimization remark (compiler stderr), which is the discriminating,
# stable signal:
#
#   * column-major element-wise map / reduction : interchanged ONLY with the
#     switch on (no remark, no reorder, with it off);
#   * transpose-in-place  a[i*W+j]:=a[j*W+i]     : REFUSED (write array is read
#     with a different index -> possible loop-carried dependence);
#   * already-contiguous nest (inner strides 1)  : declined by the cost model;
#   * float scalar reduction without fast-math    : refused (FP reassociation gate).
#
# Usage: unleashed/tests/loopinterchange_check.sh [path-to-ppcx64]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- column-major element-wise map: interchangeable (subset R) ---------------
cat > "$tmp/kmap.pp" <<'EOF'
program kmap;
{$mode objfpc}{$H+}
function f(H,W: longint): double;
var a,b: array of double; i,j: longint;
begin
  SetLength(a,H*W+1); SetLength(b,H*W+1);
  for i:=0 to H*W-1 do a[i]:=i*1.0;
  for j:=0 to W-1 do
    for i:=0 to H-1 do
      b[i*W+j]:=a[i*W+j]*2.0;
  f:=b[0];
end;
begin Writeln(f(5,7):0:1); end.
EOF

# --- column-major integer reduction: interchangeable (subset S) --------------
cat > "$tmp/kred.pp" <<'EOF'
program kred;
{$mode objfpc}{$H+}
function f(H,W: longint): int64;
var a: array of longint; i,j: longint; s: int64;
begin
  SetLength(a,H*W+1);
  for i:=0 to H*W-1 do a[i]:=i;
  s:=0;
  for j:=0 to W-1 do
    for i:=0 to H-1 do
      s:=s+a[i*W+j];
  f:=s;
end;
begin Writeln(f(5,7)); end.
EOF

# --- transpose-in-place: dependence-unsafe, MUST be refused ------------------
cat > "$tmp/ktrans.pp" <<'EOF'
program ktrans;
{$mode objfpc}{$H+}
function f(N: longint): double;
var a: array of double; i,j: longint;
begin
  SetLength(a,N*N);
  for i:=0 to N*N-1 do a[i]:=i*1.0;
  for j:=0 to N-1 do
    for i:=0 to N-1 do
      a[i*N+j]:=a[j*N+i];
  f:=a[0];
end;
begin Writeln(f(4):0:1); end.
EOF

# --- already row-contiguous nest (inner i strides 1): cost model declines ----
cat > "$tmp/kcontig.pp" <<'EOF'
program kcontig;
{$mode objfpc}{$H+}
function f(H,W: longint): double;
var a,b: array of double; i,j: longint;
begin
  SetLength(a,H*W+1); SetLength(b,H*W+1);
  for i:=0 to H*W-1 do a[i]:=i*1.0;
  for j:=0 to H-1 do
    for i:=0 to W-1 do
      b[j*W+i]:=a[j*W+i]*2.0;
  f:=b[0];
end;
begin Writeln(f(5,7):0:1); end.
EOF

# --- float scalar reduction: needs fast-math to reassociate ------------------
cat > "$tmp/kfred.pp" <<'EOF'
program kfred;
{$mode objfpc}{$H+}
function f(H,W: longint): double;
var a: array of double; i,j: longint; s: double;
begin
  SetLength(a,H*W+1);
  for i:=0 to H*W-1 do a[i]:=i*0.5;
  s:=0;
  for j:=0 to W-1 do
    for i:=0 to H-1 do
      s:=s+a[i*W+j];
  f:=s;
end;
begin Writeln(f(5,7):0:1); end.
EOF

remarks() { # $1=src  $2..=flags ; prints the loopinterchange remark lines
  local src="$1"; shift
  ( cd "$tmp" && "$CC" -Fu"$RTL" "$@" -OoREPORT "$src" -o"${src%.pp}" 2>&1 ) \
    | grep -iE 'loopinterchange:' || true
}
cnt() { grep -c "$1" <<<"$2" || true; }

rc=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; rc=1; }

# 1. map: interchanged ON, untouched OFF
on="$(remarks kmap.pp -O4 -OoLOOPINTERCHANGE)"
# -OoLOOPINTERCHANGE is now in the -O4 default set, so the OFF case disables it
# explicitly with the -OoNOLOOPINTERCHANGE negative switch.
off="$(remarks kmap.pp -O4 -OoNOLOOPINTERCHANGE)"
[ "$(cnt 'nest interchanged' "$on")" -ge 1 ] && pass "element-wise map interchanged with -OoLOOPINTERCHANGE" \
  || fail "element-wise map not interchanged with the switch on"
[ -z "$off" ] && pass "no interchange remark at all without the switch" \
  || fail "interchange remark emitted without the switch"

# 2. integer reduction: interchanged ON
on="$(remarks kred.pp -O4 -OoLOOPINTERCHANGE)"
[ "$(cnt 'nest interchanged' "$on")" -ge 1 ] && pass "integer reduction interchanged with the switch" \
  || fail "integer reduction not interchanged with the switch"

# 3. transpose-in-place: refused (recognized as a nest, then declined)
on="$(remarks ktrans.pp -O4 -OoLOOPINTERCHANGE)"
[ "$(cnt 'nest interchanged' "$on")" -eq 0 ] && pass "transpose-in-place NOT interchanged" \
  || fail "transpose-in-place was wrongly interchanged (dependence violation)"
[ "$(cnt 'the written array is also read' "$on")" -ge 1 ] \
  && pass "transpose-in-place refused for the right reason (write array also read)" \
  || fail "transpose-in-place refusal reason missing"

# 4. already-contiguous nest: cost model declines
on="$(remarks kcontig.pp -O4 -OoLOOPINTERCHANGE)"
[ "$(cnt 'nest interchanged' "$on")" -eq 0 ] && pass "already-contiguous nest NOT interchanged" \
  || fail "already-contiguous nest was needlessly interchanged"
[ "$(cnt 'not more cache-contiguous' "$on")" -ge 1 ] \
  && pass "already-contiguous nest declined by the cost model" \
  || fail "cost-model decline remark missing for the contiguous nest"

# 5. float reduction: refused without fast-math, interchanged with it
noff="$(remarks kfred.pp -O3 -OoLOOPINTERCHANGE)"
[ "$(cnt 'needs fast-math' "$noff")" -ge 1 ] \
  && pass "float reduction refused without fast-math" \
  || fail "float reduction was not gated on fast-math"
won="$(remarks kfred.pp -O4 -OoLOOPINTERCHANGE)"
[ "$(cnt 'nest interchanged' "$won")" -ge 1 ] \
  && pass "float reduction interchanged under -O4 (fast-math on)" \
  || fail "float reduction not interchanged even with fast-math"

if [ "$rc" -eq 0 ]; then echo "loopinterchange_check: ALL PASS"; fi
exit "$rc"
