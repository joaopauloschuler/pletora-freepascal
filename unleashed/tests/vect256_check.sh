#!/usr/bin/env bash
# Codegen assertion for the -OoVECT256 AVX-256 (ymm) autovectorization width.
#
#   1. With -OoVECT256 on an AVX fputype the element-wise and reduction bodies
#      are widened to 256-bit ymm ops: %ymm operands appear, the packed moves are
#      vmovups/%ymm, and a reduction epilogue uses vextractf128 to fold the two
#      128-bit halves before the scalar horizontal sum. Under -Cfavx2 the dot
#      product still fuses to a packed vfmadd231ps over %ymm.
#   2. WITHOUT -OoVECT256 (plain -OoVECTORIZE on the same fputype) the bodies
#      stay 128-bit: no %ymm, no vextractf128.
#   3. -OoVECT256 on a NON-AVX fputype (-Cfsse64) is inert: it falls back to the
#      128-bit path -- no %ymm, no vextractf128.
#   4. The -OoREPORT remark reflects the chosen width: width=ymm256 with
#      -OoVECT256 on AVX, width=xmm128 otherwise.
#
# The bundled byte-based %CHECKBIN_* directive cannot match instruction
# mnemonics, so we inspect the emitted assembly (-al -s) instead.  Codegen-only:
# nothing here runs an AVX binary, so it is valid on a host without AVX.
#
# Usage: unleashed/tests/vect256_check.sh [path-to-ppcx64]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# element-wise (arr_arr + arr_scalar + copy) and reduction (sum + dot) kernels
# over simple non-aliased local dynamic arrays -- exactly the shapes the loop
# vectorizer widens.
cat > "$tmp/kew.pp" <<'EOF'
program kew;
{$mode objfpc}{$H+}
type TS = array of single;
function ew(n: longint; s: single): single;
var a,b,r: TS; i: longint; acc: single;
begin
  SetLength(a,n); SetLength(b,n); SetLength(r,n);
  for i:=0 to n-1 do begin a[i]:=i; b[i]:=2*i; end;
  for i:=0 to n-1 do r[i]:=a[i]+b[i];   { arr_arr }
  for i:=0 to n-1 do r[i]:=a[i]*s;      { arr_scalar }
  for i:=0 to n-1 do r[i]:=a[i];        { copy }
  { consume every element so the stores are not dead-store-eliminated }
  acc:=0; for i:=0 to n-1 do acc:=acc+r[i]; ew:=acc;
end;
begin Writeln(ew(64, 3.0):0:1); end.
EOF

cat > "$tmp/kr.pp" <<'EOF'
program kr;
{$mode objfpc}{$H+}
type TS = array of single;
function dot(a,b: TS; n: longint): single;
var i: longint; s: single;
begin s:=0; for i:=0 to n-1 do s:=s+a[i]*b[i]; dot:=s; end;
function sum(a: TS; n: longint): single;
var i: longint; s: single;
begin s:=0; for i:=0 to n-1 do s:=s+a[i]; sum:=s; end;
var a,b: TS;
begin SetLength(a,64); SetLength(b,64); Writeln(dot(a,b,64):0:1, sum(a,64):0:1); end.
EOF

asm() { # $1=src $2..=flags -> emits ${src%.pp}.s next to it
  local src="$1"; shift
  ( cd "$tmp" && "$CC" -Fu"$RTL" "$@" -al -s "$src" >/dev/null 2>&1 )
}

ymm_re='%ymm[0-9]+'
rc=0

# ---- 1. -OoVECT256 on AVX2: ymm widening ----
asm kew.pp -O4 -OoVECTORIZE -OoVECT256 -Cfavx2
asm kr.pp  -O4 -OoVECTORIZE -OoVECT256 -OoFASTMATH -Cfavx2
ew_ymm=$(grep -cE "$ymm_re" "$tmp/kew.s" || true)
ew_vmovups_y=$(grep -cE "vmovups[[:space:]].*$ymm_re" "$tmp/kew.s" || true)
r_ymm=$(grep -cE "$ymm_re" "$tmp/kr.s" || true)
r_ext=$(grep -cE 'vextractf128' "$tmp/kr.s" || true)
r_fma=$(grep -cE "vfmadd231ps[[:space:]].*$ymm_re" "$tmp/kr.s" || true)
echo "VECT256/AVX2 elemwise: ymm=$ew_ymm vmovups.ymm=$ew_vmovups_y"
echo "VECT256/AVX2 reduce  : ymm=$r_ymm vextractf128=$r_ext vfmadd231ps.ymm=$r_fma"
[ "$ew_ymm" -ge 1 ]       || { echo "FAIL: element-wise body not widened to ymm"; rc=1; }
[ "$ew_vmovups_y" -ge 1 ] || { echo "FAIL: element-wise load/store not a 256-bit vmovups"; rc=1; }
[ "$r_ymm" -ge 1 ]        || { echo "FAIL: reduction body not widened to ymm"; rc=1; }
[ "$r_ext" -ge 1 ]        || { echo "FAIL: reduction epilogue missing vextractf128"; rc=1; }
[ "$r_fma" -ge 1 ]        || { echo "FAIL: dot did not fuse to a packed vfmadd231ps over ymm"; rc=1; }

# ---- 2. no -OoVECT256 on AVX2: stays 128-bit ----
asm kew.pp -O4 -OoVECTORIZE -Cfavx2
asm kr.pp  -O4 -OoVECTORIZE -OoFASTMATH -Cfavx2
ew_ymm0=$(grep -cE "$ymm_re" "$tmp/kew.s" || true)
r_ymm0=$(grep -cE "$ymm_re" "$tmp/kr.s" || true)
r_ext0=$(grep -cE 'vextractf128' "$tmp/kr.s" || true)
echo "plain/AVX2            : elemwise ymm=$ew_ymm0  reduce ymm=$r_ymm0 vextractf128=$r_ext0 (all must be 0)"
[ "$ew_ymm0" -eq 0 ] || { echo "FAIL: element-wise emitted ymm without -OoVECT256"; rc=1; }
[ "$r_ymm0" -eq 0 ]  || { echo "FAIL: reduction emitted ymm without -OoVECT256"; rc=1; }
[ "$r_ext0" -eq 0 ]  || { echo "FAIL: emitted vextractf128 without -OoVECT256"; rc=1; }

# ---- 3. -OoVECT256 on a non-AVX fputype (-Cfsse64): inert, stays 128-bit ----
asm kew.pp -O4 -OoVECTORIZE -OoVECT256 -Cfsse64
asm kr.pp  -O4 -OoVECTORIZE -OoVECT256 -OoFASTMATH -Cfsse64
ew_ymms=$(grep -cE "$ymm_re" "$tmp/kew.s" || true)
r_ymms=$(grep -cE "$ymm_re" "$tmp/kr.s" || true)
r_exts=$(grep -cE 'vextractf128' "$tmp/kr.s" || true)
echo "VECT256/SSE64        : elemwise ymm=$ew_ymms  reduce ymm=$r_ymms vextractf128=$r_exts (all must be 0)"
[ "$ew_ymms" -eq 0 ] || { echo "FAIL: -OoVECT256 emitted ymm on a non-AVX (SSE) fputype"; rc=1; }
[ "$r_ymms" -eq 0 ]  || { echo "FAIL: -OoVECT256 emitted ymm reduction on a non-AVX fputype"; rc=1; }
[ "$r_exts" -eq 0 ]  || { echo "FAIL: -OoVECT256 emitted vextractf128 on a non-AVX fputype"; rc=1; }

# ---- 4. -OoREPORT reflects the chosen width ----
rep256=$( ( cd "$tmp" && "$CC" -Fu"$RTL" -O4 -OoVECTORIZE -OoVECT256 -OoREPORT -OoFASTMATH -Cfavx2 kr.pp 2>&1 ) || true )
rep128=$( ( cd "$tmp" && "$CC" -Fu"$RTL" -O4 -OoVECTORIZE -OoREPORT -OoFASTMATH -Cfavx2 kr.pp 2>&1 ) || true )
# the ymm path appends " width=ymm256"; the default 128-bit path appends no
# width suffix (its remark stays byte-identical to the pre-AVX-256 wording).
w256=$(printf '%s\n' "$rep256" | grep -cE 'vectorize: reduction loop vectorized, VF=8, tail=scalar width=ymm256' || true)
w128=$(printf '%s\n' "$rep128" | grep -cE 'vectorize: reduction loop vectorized, VF=4, tail=scalar$' || true)
w128bad=$(printf '%s\n' "$rep128" | grep -cE 'width=ymm256' || true)
echo "REPORT width         : ymm256(VECT256,VF=8)=$w256  xmm128(plain,VF=4)=$w128  ymm-tag-in-plain=$w128bad"
[ "$w256" -ge 1 ]    || { echo "FAIL: -OoREPORT did not report VF=8 width=ymm256 under -OoVECT256"; rc=1; }
[ "$w128" -ge 1 ]    || { echo "FAIL: -OoREPORT did not report the plain VF=4 remark without -OoVECT256"; rc=1; }
[ "$w128bad" -eq 0 ] || { echo "FAIL: -OoREPORT emitted a ymm256 width tag without -OoVECT256"; rc=1; }

[ "$rc" -eq 0 ] && echo "PASS: -OoVECT256 widens to ymm on AVX (vextractf128 epilogue, packed FMA), stays 128-bit without it or on a non-AVX fputype, and -OoREPORT reflects the width"
exit "$rc"
