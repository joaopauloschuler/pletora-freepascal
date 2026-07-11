#!/usr/bin/env bash
# Codegen assertion for the -OoINT8DOT quantized int8 dot-product idiom.
#
# The reduction  s := s + a[i]*b[i]  over  a,b : array of shortint  with a 32-bit
# integer accumulator s is lowered to a widening integer-SIMD MAC:
#   * the 8-bit windows are sign-extended to 16-bit (pmovsxbw under SSE4.1/AVX,
#     movq+punpcklbw+psraw on the SSE2 baseline, vpmovsxbw ymm under AVX2),
#   * multiplied and adjacent-pair-summed into 32-bit lanes with (v)pmaddwd,
#   * accumulated register-resident with (v)paddd, horizontally summed after.
# The scalar per-element  imul  disappears from the loop.
#
# Asserts:
#   1. WITH -OoINT8DOT the MAC (pmaddwd) appears and the loop's scalar imul is gone.
#   2. WITHOUT -OoINT8DOT (default / -OoNOINT8DOT) the loop stays scalar: pmaddwd
#      absent, imul present.
#   3. The 128-bit baseline (SSE2), SSE4.1 and AVX2/VECT256 (ymm, vpmaddwd) paths.
#   4. Declines that MUST stay scalar even with -OoINT8DOT: a single-precision
#      float dot, a 16-bit (smallint) dot, an 8-bit accumulator, and -Co overflow
#      checking -- none may emit pmaddwd.
#
# Usage: unleashed/tests/int8dot_check.sh [path-to-ppcx64]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# int8 dot kernel (the only loop in the file, so a whole-file grep is unambiguous)
cat > "$tmp/k8.pp" <<'EOF'
program k8;
{$mode objfpc}{$H+}
type TB = array of shortint;
function dot(a,b: TB; n: longint): longint;
var i: longint; s: longint;
begin s:=0; for i:=0 to n-1 do s:=s+a[i]*b[i]; dot:=s; end;
var a,b: TB;
begin SetLength(a,64); SetLength(b,64); Writeln(dot(a,b,64)); end.
EOF

# single-precision float dot: must never be taken by INT8DOT
cat > "$tmp/kf.pp" <<'EOF'
program kf;
{$mode objfpc}{$H+}
type TS = array of single;
function dot(a,b: TS; n: longint): single;
var i: longint; s: single;
begin s:=0; for i:=0 to n-1 do s:=s+a[i]*b[i]; dot:=s; end;
var a,b: TS;
begin SetLength(a,64); SetLength(b,64); Writeln(dot(a,b,64):0:3); end.
EOF

# 16-bit (smallint) dot: element width is not 8-bit -> declines
cat > "$tmp/k16.pp" <<'EOF'
program k16;
{$mode objfpc}{$H+}
type TW = array of smallint;
function dot(a,b: TW; n: longint): longint;
var i: longint; s: longint;
begin s:=0; for i:=0 to n-1 do s:=s+a[i]*b[i]; dot:=s; end;
var a,b: TW;
begin SetLength(a,64); SetLength(b,64); Writeln(dot(a,b,64)); end.
EOF

# 8-bit accumulator: accumulator is not 32-bit -> declines
cat > "$tmp/ka8.pp" <<'EOF'
program ka8;
{$mode objfpc}{$H+}
type TB = array of shortint;
function dot(a,b: TB; n: longint): shortint;
var i: longint; s: shortint;
begin s:=0; for i:=0 to n-1 do s:=s+a[i]*b[i]; dot:=s; end;
var a,b: TB;
begin SetLength(a,64); SetLength(b,64); Writeln(dot(a,b,64)); end.
EOF

compile() { # $1=src ; rest=flags -> writes ${src%.pp}.s
  local src="$1"; shift
  ( cd "$tmp" && "$CC" -Fu"$RTL" -O4 "$@" -al -s "$src" >/dev/null 2>&1 )
}

# integer scalar multiply inside the loop (the un-vectorized MAC)
imul_re='(^|[^[:alnum:]])imul[lq]?[[:space:]]'

rc=0

# ---- baseline WITHOUT INT8DOT: stays scalar (its imul count is the reference) ----
compile k8.pp -Cfsse64
s="$tmp/k8.s"
mac_off=$(grep -cE '(^|[^v])pmaddwd' "$s" || true)
imul_off=$(grep -cE "$imul_re" "$s" || true)
echo "SSE64  int8dot OFF: pmaddwd=$mac_off (must be 0)  imul=$imul_off (must be >=1)"
[ "$mac_off" -eq 0 ]  || { echo "FAIL: emitted pmaddwd without -OoINT8DOT"; rc=1; }
[ "$imul_off" -ge 1 ] || { echo "FAIL: scalar imul missing without -OoINT8DOT (loop unexpectedly transformed?)"; rc=1; }

# ---- 1. SSE2 baseline WITH INT8DOT: pmaddwd present; the hot-loop imul is gone.
# A single imul may remain in the COLD scalar-remainder tail, so assert the count
# strictly drops vs the un-vectorized baseline (the scalar MAC left the hot loop). ----
compile k8.pp -OoINT8DOT -Cfsse64
s="$tmp/k8.s"
mac=$(grep -cE '(^|[^v])pmaddwd' "$s" || true)
sxt=$(grep -cE '(^|[^v])psraw' "$s" || true)
imul=$(grep -cE "$imul_re" "$s" || true)
echo "SSE64  int8dot ON : pmaddwd=$mac psraw(sext)=$sxt imul=$imul (< OFF=$imul_off; only cold tail)"
[ "$mac" -ge 1 ]  || { echo "FAIL: expected pmaddwd (int8 MAC not vectorized) on SSE2 baseline"; rc=1; }
[ "$sxt" -ge 1 ]  || { echo "FAIL: expected psraw sign-extend on SSE2 baseline"; rc=1; }
[ "$imul" -lt "$imul_off" ] || { echo "FAIL: scalar imul count did not drop (MAC did not leave the hot loop)"; rc=1; }
[ "$imul" -le 1 ] || { echo "FAIL: more than the single cold-tail imul survived"; rc=1; }

# ---- 2b. explicit -OoNOINT8DOT also stays scalar ----
compile k8.pp -OoINT8DOT -OoNOINT8DOT -Cfsse64
s="$tmp/k8.s"
mac=$(grep -cE '(^|[^v])pmaddwd' "$s" || true)
echo "SSE64  NOINT8DOT  : pmaddwd=$mac (must be 0)"
[ "$mac" -eq 0 ] || { echo "FAIL: -OoNOINT8DOT did not disable the transform"; rc=1; }

# ---- 3. SSE4.1: pmovsxbw sign-extend + pmaddwd ----
compile k8.pp -OoINT8DOT -Cfsse41
s="$tmp/k8.s"
sxbw=$(grep -cE '(^|[^v])pmovsxbw' "$s" || true)
mac=$(grep -cE '(^|[^v])pmaddwd' "$s" || true)
echo "SSE41  int8dot ON : pmovsxbw=$sxbw pmaddwd=$mac"
[ "$sxbw" -ge 1 ] || { echo "FAIL: expected pmovsxbw sign-extend under SSE4.1"; rc=1; }
[ "$mac" -ge 1 ]  || { echo "FAIL: expected pmaddwd under SSE4.1"; rc=1; }

# ---- 4. AVX2 + VECT256: ymm widening MAC (vpmovsxbw/vpmaddwd/vpaddd + vextracti128) ----
compile k8.pp -OoINT8DOT -OoVECT256 -Cfavx2
s="$tmp/k8.s"
ymm_sxbw=$(grep -cE 'vpmovsxbw.*%ymm' "$s" || true)
ymm_mac=$(grep -cE 'vpmaddwd.*%ymm' "$s" || true)
ext=$(grep -cE 'vextracti128' "$s" || true)
imul=$(grep -cE "$imul_re" "$s" || true)
echo "AVX2   ymm256     : vpmovsxbw.ymm=$ymm_sxbw vpmaddwd.ymm=$ymm_mac vextracti128=$ext imul=$imul (<=1 cold tail)"
[ "$ymm_sxbw" -ge 1 ] || { echo "FAIL: expected ymm vpmovsxbw under -OoVECT256+AVX2"; rc=1; }
[ "$ymm_mac" -ge 1 ]  || { echo "FAIL: expected ymm vpmaddwd under -OoVECT256+AVX2"; rc=1; }
[ "$ext" -ge 1 ]      || { echo "FAIL: expected vextracti128 in the ymm horizontal-sum epilogue"; rc=1; }
[ "$imul" -le 1 ]     || { echo "FAIL: more than the single cold-tail imul survived in the ymm path"; rc=1; }

# ---- 5. declines that must STAY scalar even with -OoINT8DOT ----
# 5a. single-precision float dot
compile kf.pp -OoINT8DOT -Cfsse64
mac=$(grep -cE '(^|[^v])pmaddwd' "$tmp/kf.s" || true)
echo "float  dot        : pmaddwd=$mac (must be 0)"
[ "$mac" -eq 0 ] || { echo "FAIL: INT8DOT wrongly took a single-precision float dot"; rc=1; }

# 5b. 16-bit (smallint) dot
compile k16.pp -OoINT8DOT -Cfsse64
mac=$(grep -cE '(^|[^v])pmaddwd' "$tmp/k16.s" || true)
echo "int16  dot        : pmaddwd=$mac (must be 0)"
[ "$mac" -eq 0 ] || { echo "FAIL: INT8DOT wrongly took a 16-bit (non-int8) dot"; rc=1; }

# 5c. 8-bit accumulator
compile ka8.pp -OoINT8DOT -Cfsse64
mac=$(grep -cE '(^|[^v])pmaddwd' "$tmp/ka8.s" || true)
echo "int8-acc dot      : pmaddwd=$mac (must be 0)"
[ "$mac" -eq 0 ] || { echo "FAIL: INT8DOT wrongly took an 8-bit-accumulator dot"; rc=1; }

# 5d. overflow checking (-Co) must refuse
compile k8.pp -OoINT8DOT -Cfsse64 -Co
mac=$(grep -cE '(^|[^v])pmaddwd' "$tmp/k8.s" || true)
echo "-Co    int8dot    : pmaddwd=$mac (must be 0)"
[ "$mac" -eq 0 ] || { echo "FAIL: INT8DOT fired under -Co overflow checking"; rc=1; }

[ "$rc" -eq 0 ] && echo "PASS: int8 dot-product MAC fires only under -OoINT8DOT on 8-bit x 8-bit -> 32-bit reductions; all declines stay scalar"
exit "$rc"
