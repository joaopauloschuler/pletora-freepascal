#!/usr/bin/env bash
# Codegen / diagnostic assertion for the -OoLOOPTILE loop-tiling (cache-blocking)
# pass: a perfect three-deep counted matmul-shaped reduction nest
#
#     for i: for j: for k: c[i*N+j] := c[i*N+j] + a[i*K+k]*b[k*N+j];
#
# is blocked into cache-sized tiles over the two output loops i and j, with the
# point loops reordered i/k/j (j and k interchanged) so the inner loop strides the
# contiguous dimension.  The transform fires only under the opt-in switch and only
# for the sound, reuse-bearing matmul shape; it refuses unsafe / non-matching
# shapes.  We assert on the -OoREPORT optimization remark (compiler stderr), the
# discriminating, stable signal:
#
#   * matmul float/integer reduction : tiled ONLY with the switch on;
#   * accumulator array read in the addend (loop-carried dependence) : REFUSED;
#   * a call in the reduction body                                   : REFUSED;
#   * no operand reused across both tiled loops                      : declined;
#   * float reduction without fast-math                             : refused.
#
# Usage: unleashed/tests/looptile_check.sh [path-to-ppcx64]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- matmul, single precision: tileable (needs fast-math, on at -O4) ---------
cat > "$tmp/mmf.pp" <<'EOF'
program mmf;
{$mode objfpc}{$H+}
function f(rows,cols,inner: longint): single;
var a,b,c: array of single; i,j,k: longint;
begin
  SetLength(a,rows*inner+1); SetLength(b,inner*cols+1); SetLength(c,rows*cols+1);
  for i:=0 to rows*inner-1 do a[i]:=(i mod 7)*0.5;
  for i:=0 to inner*cols-1 do b[i]:=(i mod 5)*0.25;
  for i:=0 to rows*cols-1 do c[i]:=0.0;
  for i:=0 to rows-1 do
    for j:=0 to cols-1 do
      for k:=0 to inner-1 do
        c[i*cols+j]:=c[i*cols+j]+a[i*inner+k]*b[k*cols+j];
  f:=c[0];
end;
begin Writeln(f(80,80,80):0:1); end.
EOF

# --- matmul, integer: tileable without fast-math (integer + is exact) --------
cat > "$tmp/mmi.pp" <<'EOF'
program mmi;
{$mode objfpc}{$H+}
function f(rows,cols,inner: longint): int64;
var a,b,c: array of longint; i,j,k: longint;
begin
  SetLength(a,rows*inner+1); SetLength(b,inner*cols+1); SetLength(c,rows*cols+1);
  for i:=0 to rows*inner-1 do a[i]:=(i mod 7);
  for i:=0 to inner*cols-1 do b[i]:=(i mod 5);
  for i:=0 to rows*cols-1 do c[i]:=0;
  for i:=0 to rows-1 do
    for j:=0 to cols-1 do
      for k:=0 to inner-1 do
        c[i*cols+j]:=c[i*cols+j]+a[i*inner+k]*b[k*cols+j];
  f:=c[rows*cols-1];
end;
begin Writeln(f(80,80,80)); end.
EOF

# --- accumulator array read in the addend: loop-carried dependence, REFUSED --
cat > "$tmp/mdep.pp" <<'EOF'
program mdep;
{$mode objfpc}{$H+}
function f(rows,cols,inner: longint): int64;
var a,c: array of longint; i,j,k: longint;
begin
  SetLength(a,rows*inner+1); SetLength(c,rows*cols+1);
  for i:=0 to rows*inner-1 do a[i]:=(i mod 7);
  for i:=0 to rows*cols-1 do c[i]:=1;
  for i:=0 to rows-1 do
    for j:=0 to cols-1 do
      for k:=0 to inner-1 do
        c[i*cols+j]:=c[i*cols+j]+a[i*inner+k]*c[k*cols+j];
  f:=c[0];
end;
begin Writeln(f(80,80,80)); end.
EOF

# --- a call in the reduction body: REFUSED -----------------------------------
cat > "$tmp/mcall.pp" <<'EOF'
program mcall;
{$mode objfpc}{$H+}
function g(x: longint): longint; begin g:=x*2; end;
function f(rows,cols,inner: longint): int64;
var a,c: array of longint; i,j,k: longint;
begin
  SetLength(a,rows*inner+1); SetLength(c,rows*cols+1);
  for i:=0 to rows*inner-1 do a[i]:=(i mod 7);
  for i:=0 to rows*cols-1 do c[i]:=0;
  for i:=0 to rows-1 do
    for j:=0 to cols-1 do
      for k:=0 to inner-1 do
        c[i*cols+j]:=c[i*cols+j]+g(a[i*inner+k]);
  f:=c[0];
end;
begin Writeln(f(80,80,80)); end.
EOF

# --- no operand reused across both tiled loops: cost model declines ----------
# addend a[i*cols+j]*k depends on BOTH i and j, so nothing is reused across a
# tiled loop -- tiling would only add overhead.
cat > "$tmp/mnoreuse.pp" <<'EOF'
program mnoreuse;
{$mode objfpc}{$H+}
function f(rows,cols,inner: longint): int64;
var a,c: array of longint; i,j,k: longint;
begin
  SetLength(a,rows*cols+1); SetLength(c,rows*cols+1);
  for i:=0 to rows*cols-1 do a[i]:=(i mod 7);
  for i:=0 to rows*cols-1 do c[i]:=0;
  for i:=0 to rows-1 do
    for j:=0 to cols-1 do
      for k:=0 to inner-1 do
        c[i*cols+j]:=c[i*cols+j]+a[i*cols+j]*k;
  f:=c[0];
end;
begin Writeln(f(80,80,80)); end.
EOF

remarks() { # $1=src  $2..=flags ; prints the looptile remark lines
  local src="$1"; shift
  ( cd "$tmp" && "$CC" -Fu"$RTL" "$@" -OoREPORT "$src" -o"${src%.pp}" 2>&1 ) \
    | grep -iE 'looptile:' || true
}
cnt() { grep -c "$1" <<<"$2" || true; }

rc=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; rc=1; }

# 1. float matmul: tiled ON (fast-math at -O4), untouched OFF
on="$(remarks mmf.pp -O4 -OoLOOPTILE)"
off="$(remarks mmf.pp -O4)"
[ "$(cnt 'cache-blocked into' "$on")" -ge 1 ] && pass "float matmul tiled with -OoLOOPTILE" \
  || fail "float matmul not tiled with the switch on"
[ -z "$off" ] && pass "no tiling remark at all without the switch" \
  || fail "tiling remark emitted without the switch"

# 2. integer matmul: tiled ON (no fast-math needed)
on="$(remarks mmi.pp -O3 -OoLOOPTILE)"
[ "$(cnt 'cache-blocked into' "$on")" -ge 1 ] && pass "integer matmul tiled with the switch" \
  || fail "integer matmul not tiled with the switch"

# 3. accumulator array read in the addend: refused (recognized, then declined)
on="$(remarks mdep.pp -O3 -OoLOOPTILE)"
[ "$(cnt 'cache-blocked into' "$on")" -eq 0 ] && pass "dependence-carrying nest NOT tiled" \
  || fail "dependence-carrying nest was wrongly tiled"
[ "$(cnt 'accumulator array is read' "$on")" -ge 1 ] \
  && pass "dependence nest refused for the right reason (accumulator read in addend)" \
  || fail "dependence-nest refusal reason missing"

# 4. a call in the body: refused
on="$(remarks mcall.pp -O3 -OoLOOPTILE)"
[ "$(cnt 'cache-blocked into' "$on")" -eq 0 ] && pass "call-containing body NOT tiled" \
  || fail "call-containing body was wrongly tiled"
[ "$(cnt 'unsupported operation' "$on")" -ge 1 ] \
  && pass "call body refused for the right reason (unsupported operation)" \
  || fail "call-body refusal reason missing"

# 5. no reuse across both tiled loops: cost model declines
on="$(remarks mnoreuse.pp -O3 -OoLOOPTILE)"
[ "$(cnt 'cache-blocked into' "$on")" -eq 0 ] && pass "no-reuse nest NOT tiled" \
  || fail "no-reuse nest was needlessly tiled"
[ "$(cnt 'not improve locality' "$on")" -ge 1 ] \
  && pass "no-reuse nest declined by the cost model" \
  || fail "cost-model decline remark missing for the no-reuse nest"

# 6. float matmul without fast-math: refused
noff="$(remarks mmf.pp -O3 -OoLOOPTILE)"
[ "$(cnt 'needs fast-math' "$noff")" -ge 1 ] \
  && pass "float reduction tiling refused without fast-math" \
  || fail "float reduction tiling was not gated on fast-math"

if [ "$rc" -eq 0 ]; then echo "looptile_check: ALL PASS"; fi
exit "$rc"
