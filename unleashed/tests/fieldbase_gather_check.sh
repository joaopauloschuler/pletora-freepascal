#!/usr/bin/env bash
#
# AVX2 gather (-OoGATHER): object-field array-base recognition assertions.
#
# The fork's loop recognizers used a simple-var rule (rangeelim_simple_var): an
# array base had to be a stable, non-address-taken LOCAL or PARAMETER.  That
# rejected  Self.FData -style object-field dynamic-array bases (as in neural-api
# TNNetVolume.FData), so the AVX2 gather never fired inside real methods.
#
# -OoGATHER now also accepts an array base of the form  <stable-ref>.<field>  for
# BOTH the gathered data array a and the index array idx (vect_array_base_ok).  The
# gather build already routes gvec/ivec through the vectorizer's field-base
# preheader-snapshot machinery (hoist_field_bases) and the whole-loop soundness
# gate (field_base_gate: no call in the body, field handle not reassigned) that the
# element-wise vectorizer slice landed.
#
# Asserts (AVX2 target, -Cfavx2):
#   1. A class-method indexed sum reduction  s := s + FData[FIdx[i]]  over FIELD
#      bases emits vgatherdps (xmm VF=4) and the -OoREPORT gather remark.
#   2. With -OoVECT256 it widens to a ymm gather (VF=8).
#   3. It DECLINES (stays scalar, no vgatherdps) when the body makes a call.
#   4. Bit-exact runtime: the fixture's checksum is identical with the gather
#      (-O4 -OoGATHER -Cfavx2) and without it (-O-).
#
# Usage: unleashed/tests/fieldbase_gather_check.sh [path-to-ppcx64]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- indexed sum reduction over class-FIELD data + index arrays ----------------
cat > "$tmp/kg.pp" <<'EOF'
program kg;
{$mode objfpc}{$H+}{$Q-}{$R-}
type TV = class FData: array of single; FIdx: array of longint; function GSum(n: longint): single; end;
function TV.GSum(n: longint): single;
var i: longint; s: single;
begin s:=0; for i:=0 to n-1 do s:=s+FData[FIdx[i]]; GSum:=s; end;
var v: TV;
begin v:=TV.Create; SetLength(v.FData,64); SetLength(v.FIdx,64); Writeln(v.GSum(64):0:3); end.
EOF

# --- same but the body makes a call: must DECLINE ------------------------------
cat > "$tmp/kc.pp" <<'EOF'
program kc;
{$mode objfpc}{$H+}{$Q-}{$R-}
var g: longint; function bump(x: single): single; begin inc(g); bump:=x; end;
type TV = class FData: array of single; FIdx: array of longint; function GSum(n: longint): single; end;
function TV.GSum(n: longint): single;
var i: longint; s: single;
begin s:=0; for i:=0 to n-1 do s:=s+bump(FData[FIdx[i]]); GSum:=s; end;
var v: TV;
begin v:=TV.Create; SetLength(v.FData,64); SetLength(v.FIdx,64); Writeln(v.GSum(64):0:3); end.
EOF

compile() { # $1=src ; rest=flags -> writes ${src%.pp}.s in $tmp, report to .rep
  local src="$1"; shift
  ( cd "$tmp" && "$CC" -Fu"$RTL" "$@" -al -s "$src" > "${src%.pp}.rep" 2>&1 )
}
gcount() { grep -icE 'vgatherdps' "$1" || true; }
gxmm()   { grep -icE 'vgatherdps[[:space:]]+%xmm' "$1" || true; }
gymm()   { grep -icE 'vgatherdps[[:space:]]+%ymm' "$1" || true; }

rc=0

# ---- 1. field-base gather emits xmm vgatherdps + report remark ----
compile kg.pp -O4 -OoGATHER -Cfavx2 -OoREPORT
x=$(gxmm "$tmp/kg.s"); r=$(grep -cE 'gather: indexed-load sum reduction vectorized' "$tmp/kg.rep" || true)
echo "field gather xmm  : vgatherdps.xmm=$x report=$r (both must be >=1)"
[ "$x" -ge 1 ] || { echo "FAIL: no xmm vgatherdps for a class-field indexed reduction"; rc=1; }
[ "$r" -ge 1 ] || { echo "FAIL: -OoREPORT did not report the field-base gather"; rc=1; }

# ---- 2. ymm gather under -OoVECT256 ----
compile kg.pp -O4 -OoGATHER -OoVECT256 -Cfavx2
y=$(gymm "$tmp/kg.s")
echo "field gather ymm  : vgatherdps.ymm=$y (must be >=1)"
[ "$y" -ge 1 ] || { echo "FAIL: no ymm vgatherdps with -OoVECT256"; rc=1; }

# ---- 3. body makes a call: must DECLINE (no gather) ----
compile kc.pp -O4 -OoGATHER -Cfavx2
g=$(gcount "$tmp/kc.s")
echo "field + call      : vgatherdps=$g (must be 0)"
[ "$g" -eq 0 ] || { echo "FAIL: gathered a field-base loop whose body makes a call"; rc=1; }

# ---- 4. bit-exact runtime: gather checksum == -O- checksum ----
fx="$here/testfiles/fieldbase/fieldbase_gather_runtime.pp"
( cd "$tmp" && "$CC" -Fu"$RTL" -O4 -OoGATHER -OoVECT256 -Cfavx2 "$fx" -o"$tmp/fr_o4" >/dev/null 2>&1 )
( cd "$tmp" && "$CC" -Fu"$RTL" -O- "$fx" -o"$tmp/fr_o0" >/dev/null 2>&1 )
o4=$("$tmp/fr_o4"); o0=$("$tmp/fr_o0")
echo "runtime O4=$o4  O-=$o0"
[ "$o4" = "$o0" ] || { echo "FAIL: field-base gather checksum differs from -O- (miscompile)"; rc=1; }

if [ "$rc" -eq 0 ]; then
  echo "fieldbase_gather_check: PASS"
else
  echo "fieldbase_gather_check: FAIL"
fi
exit "$rc"
