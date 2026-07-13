#!/usr/bin/env bash
#
# Loop tiling / cache blocking: object-field array-base recognition assertions.
#
# The fork's loop recognizers used a simple-var rule (rangeelim_simple_var): an
# array base had to be a stable, non-address-taken LOCAL or PARAMETER.  That
# rejected  Self.FData -style object-field dynamic-array bases (as in neural-api
# TNNetVolume.FData), so loop tiling never fired inside real methods.
#
# -OoLOOPTILE (an -O4 default) now also accepts an array base of the form
# <stable-ref>.<field> for the accumulator array AND every read operand, via the
# shared ic_write_base_sym / ic_check_expr widening the interchange slice added.
# The reorder passes copy the body verbatim (no hoisting); a whole-nest gate keeps
# the field access sound (declines on any call in the nest, or a field-handle
# reference reassignment).
#
# Asserts:
#   1. A class-method perfect three-deep matmul-shaped nest over dynamic-array
#      FIELD bases is cache-blocked (-OoREPORT 'cache-blocked' remark).
#   2. It DECLINES when the reduction addend makes a call (field could be
#      reassigned).
#   3. Bit-exact runtime: the fixture's checksum is identical with the optimizer
#      (-O4) and without it (-O-).
#
# Usage: unleashed/tests/fieldbase_tile_check.sh [path-to-ppcx64]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- perfect 3-deep matmul-shaped nest over class-FIELD dynamic-array bases -----
cat > "$tmp/tf.pp" <<'EOF'
program tf;
{$mode objfpc}{$H+}{$Q-}{$R-}
type TM = class FC,FA,FB: array of single; procedure Mul(rows,cols,inner: longint); end;
procedure TM.Mul(rows,cols,inner: longint);
var i,j,k: longint;
begin
  for i:=0 to rows-1 do
    for j:=0 to cols-1 do
      for k:=0 to inner-1 do
        FC[i*cols+j] := FC[i*cols+j] + FA[i*inner+k]*FB[k*cols+j];
end;
var v: TM;
begin v:=TM.Create; SetLength(v.FC,6401);SetLength(v.FA,6401);SetLength(v.FB,6401); v.Mul(80,80,80); end.
EOF

# --- same but the reduction addend makes a call: must DECLINE -------------------
cat > "$tmp/tc.pp" <<'EOF'
program tc;
{$mode objfpc}{$H+}{$Q-}{$R-}
function g(x: single): single; begin g:=x*2; end;
type TM = class FC,FA,FB: array of single; procedure Mul(rows,cols,inner: longint); end;
procedure TM.Mul(rows,cols,inner: longint);
var i,j,k: longint;
begin
  for i:=0 to rows-1 do
    for j:=0 to cols-1 do
      for k:=0 to inner-1 do
        FC[i*cols+j] := FC[i*cols+j] + g(FA[i*inner+k]);
end;
var v: TM;
begin v:=TM.Create; SetLength(v.FC,6401);SetLength(v.FA,6401);SetLength(v.FB,6401); v.Mul(80,80,80); end.
EOF

remarks() { "$CC" -Fu"$RTL" -O4 -OoLOOPTILE -OoREPORT "$1" -o"$tmp/bin" 2>&1; }
tiled() { remarks "$1" | grep -cE 'looptile: perfect 3-deep matmul-shaped nest cache-blocked' || true; }

rc=0

# ---- 1. field-base matmul nest is tiled ----
t=$(tiled "$tmp/tf.pp")
echo "field matmul tiled : tiled=$t (must be >=1)"
[ "$t" -ge 1 ] || { echo "FAIL: field-base matmul nest not tiled"; rc=1; }

# ---- 2. addend makes a call: must DECLINE ----
t=$(tiled "$tmp/tc.pp")
echo "field + call       : tiled=$t (must be 0)"
[ "$t" -eq 0 ] || { echo "FAIL: tiled a field-base nest whose addend makes a call"; rc=1; }

# ---- 3. bit-exact runtime: optimized checksum == -O- checksum ----
fx="$here/testfiles/fieldbase/fieldbase_tile_runtime.pp"
( cd "$tmp" && "$CC" -Fu"$RTL" -O4 "$fx" -o"$tmp/fr_o4" >/dev/null 2>&1 )
( cd "$tmp" && "$CC" -Fu"$RTL" -O- "$fx" -o"$tmp/fr_o0" >/dev/null 2>&1 )
o4=$("$tmp/fr_o4"); o0=$("$tmp/fr_o0")
echo "runtime O4=$o4  O-=$o0"
[ "$o4" = "$o0" ] || { echo "FAIL: tiled checksum differs from -O- (miscompile)"; rc=1; }

if [ "$rc" -eq 0 ]; then
  echo "fieldbase_tile_check: PASS"
else
  echo "fieldbase_tile_check: FAIL"
fi
exit "$rc"
