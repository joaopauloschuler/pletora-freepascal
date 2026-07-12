#!/usr/bin/env bash
#
# Loop interchange: object-field array-base recognition assertions.
#
# The fork's loop recognizers used a simple-var rule (rangeelim_simple_var): an
# array base had to be a stable, non-address-taken LOCAL or PARAMETER.  That
# rejected  Self.FData -style object-field dynamic-array bases (as in neural-api
# TNNetVolume.FData), so loop interchange never fired inside real methods.
#
# -OoLOOPINTERCHANGE (an -O4 default) now also accepts an array base of the form
# <stable-ref>.<field> -- Self, or a simple non-aliased local/value-param
# object|class reference -- identified by its FIELD sym.  The reorder passes copy
# the loop body verbatim, so no hoisting is needed; a whole-nest gate keeps the
# field access sound (declines on any call in the nest -- a method could reassign
# the field -- or a reassignment of the field-handle reference).
#
# Asserts:
#   1. A class-method perfect two-deep COLUMN-MAJOR nest over dynamic-array FIELD
#      bases is interchanged (-OoREPORT emits the 'perfect 2-deep' remark).
#   2. It DECLINES when the loop body makes a call (a method could reassign it).
#   3. It DECLINES when the loop body reassigns the field (store through Self).
#   4. Bit-exact runtime: the fixture's checksum is identical with the optimizer
#      (-O4) and without it (-O-).
#
# Usage: unleashed/tests/fieldbase_interchange_check.sh [path-to-ppcx64]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- perfect 2-deep column-major nest over class-FIELD dynamic-array bases ------
cat > "$tmp/fi.pp" <<'EOF'
program fi;
{$mode objfpc}{$H+}{$Q-}{$R-}
type TM = class FA,FB,FC: array of longint; rows,cols: longint; procedure Go; end;
procedure TM.Go;
var i,j: longint;
begin
  for j:=0 to cols-1 do
    for i:=0 to rows-1 do
      FA[i*cols+j] := FB[i*cols+j]*3 + FC[i*cols+j];
end;
var v: TM;
begin v:=TM.Create; v.rows:=8;v.cols:=8; SetLength(v.FA,64);SetLength(v.FB,64);SetLength(v.FC,64); v.Go; end.
EOF

# --- same nest but the body makes a call: must DECLINE --------------------------
cat > "$tmp/fc.pp" <<'EOF'
program fc;
{$mode objfpc}{$H+}{$Q-}{$R-}
var g: longint;
procedure Bump; begin inc(g); end;
type TM = class FA,FB,FC: array of longint; rows,cols: longint; procedure Go; end;
procedure TM.Go;
var i,j: longint;
begin
  for j:=0 to cols-1 do
    for i:=0 to rows-1 do
      begin FA[i*cols+j] := FB[i*cols+j]*3 + FC[i*cols+j]; Bump; end;
end;
var v: TM;
begin v:=TM.Create; v.rows:=8;v.cols:=8; SetLength(v.FA,64);SetLength(v.FB,64);SetLength(v.FC,64); v.Go; end.
EOF

# --- same nest but the body reassigns the field (store through Self): DECLINE ---
cat > "$tmp/fs.pp" <<'EOF'
program fs;
{$mode objfpc}{$H+}{$Q-}{$R-}
type TM = class FA,FB,FC: array of longint; rows,cols: longint; procedure Go; end;
procedure TM.Go;
var i,j: longint;
begin
  for j:=0 to cols-1 do
    for i:=0 to rows-1 do
      begin FA[i*cols+j] := FB[i*cols+j]*3 + FC[i*cols+j]; FB := FC; end;
end;
var v: TM;
begin v:=TM.Create; v.rows:=8;v.cols:=8; SetLength(v.FA,64);SetLength(v.FB,64);SetLength(v.FC,64); v.Go; end.
EOF

# the loopinterchange remark is emitted on stdout by -OoREPORT
remarks() { "$CC" -Fu"$RTL" "$@" -O4 -OoLOOPINTERCHANGE -OoNOVECTORIZE -OoREPORT "$1" -o"$tmp/bin" 2>&1; }
fired() { remarks "$1" | grep -cE 'loopinterchange: perfect 2-deep' || true; }

rc=0

# ---- 1. field-base column-major nest interchanges ----
f=$(fired "$tmp/fi.pp")
echo "field interchange : fired=$f (must be >=1)"
[ "$f" -ge 1 ] || { echo "FAIL: field-base column-major nest not interchanged"; rc=1; }

# ---- 2. body makes a call: must DECLINE ----
f=$(fired "$tmp/fc.pp")
echo "field + call      : fired=$f (must be 0)"
[ "$f" -eq 0 ] || { echo "FAIL: interchanged a field-base nest whose body makes a call"; rc=1; }

# ---- 3. body reassigns the field: must DECLINE ----
f=$(fired "$tmp/fs.pp")
echo "field reassigned  : fired=$f (must be 0)"
[ "$f" -eq 0 ] || { echo "FAIL: interchanged a field-base nest that reassigns the field"; rc=1; }

# ---- 4. bit-exact runtime: optimized checksum == -O- checksum ----
fx="$here/testfiles/fieldbase/fieldbase_interchange_runtime.pp"
( cd "$tmp" && "$CC" -Fu"$RTL" -O4 "$fx" -o"$tmp/fr_o4" >/dev/null 2>&1 )
( cd "$tmp" && "$CC" -Fu"$RTL" -O- "$fx" -o"$tmp/fr_o0" >/dev/null 2>&1 )
o4=$("$tmp/fr_o4"); o0=$("$tmp/fr_o0")
echo "runtime O4=$o4  O-=$o0"
[ "$o4" = "$o0" ] || { echo "FAIL: interchanged checksum differs from -O- (miscompile)"; rc=1; }

if [ "$rc" -eq 0 ]; then
  echo "fieldbase_interchange_check: PASS"
else
  echo "fieldbase_interchange_check: FAIL"
fi
exit "$rc"
