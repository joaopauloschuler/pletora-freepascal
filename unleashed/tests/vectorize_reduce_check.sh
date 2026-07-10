#!/usr/bin/env bash
# Codegen assertion for the -OoVECTORIZE sum / dot-product reduction vectorizer,
# covering the two register-accumulator + packed-FMA follow-ups:
#
#   1. Register-resident accumulator. The packed accumulator lives in an xmm
#      register across the whole vector loop (seeded before it, kept in-register
#      in the body, horizontally summed after it) -- it must NEVER be stored back
#      to / reloaded from a stack slot inside the loop.  So the emitted assembly
#      for a pure reduction kernel must contain a packed add (the loop is really
#      vectorized) yet ZERO packed stores of an xmm register to a stack slot
#      (%rsp/%rbp) -- the old memory-backed accumulator emitted exactly such a
#      movups spill/reload every iteration.
#
#   2. Packed FMA under the fast-math + FMA gate. On an FMA-capable target
#      (-Cfavx2) the dot product fuses its packed multiply-add into vfmadd231ps
#      (single) / vfmadd231pd (double); mul+add must be gone. On a non-FMA target
#      the mul+add stays: SSE (-Cfsse64) keeps mulps+addps, AVX-without-FMA
#      (-Cfavx) keeps vmulps+vaddps, and neither emits any vfmadd.
#
# The bundled byte-based %CHECKBIN_* directive cannot match instruction
# mnemonics, so we inspect the emitted assembly (-al -s) instead.
#
# Usage: unleashed/tests/vectorize_reduce_check.sh [path-to-ppcx64]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# single-precision sum + dot kernels (the only FP loops in the program, so a
# whole-file grep unambiguously inspects the vectorized reduction bodies)
cat > "$tmp/ks.pp" <<'EOF'
program ks;
{$mode objfpc}{$H+}
type TS = array of single;
function dot(a,b: TS; n: longint): single;
var i: longint; s: single;
begin s:=0; for i:=0 to n-1 do s:=s+a[i]*b[i]; dot:=s; end;
function sum(a: TS; n: longint): single;
var i: longint; s: single;
begin s:=0; for i:=0 to n-1 do s:=s+a[i]; sum:=s; end;
var a,b: TS;
begin SetLength(a,64); SetLength(b,64); Writeln(dot(a,b,64):0:3, sum(a,64):0:3); end.
EOF

# double-precision dot kernel (for vfmadd231pd)
cat > "$tmp/kd.pp" <<'EOF'
program kd;
{$mode objfpc}{$H+}
type TD = array of double;
function dot(a,b: TD; n: longint): double;
var i: longint; s: double;
begin s:=0; for i:=0 to n-1 do s:=s+a[i]*b[i]; dot:=s; end;
var a,b: TD;
begin SetLength(a,64); SetLength(b,64); Writeln(dot(a,b,64):0:3); end.
EOF

compile() { # $1=src $2=flags -> writes ${src%.pp}.s next to it
  local src="$1"; shift
  ( cd "$tmp" && "$CC" -Fu"$RTL" -O4 -OoVECTORIZE -OoFASTMATH "$@" -al -s "$src" >/dev/null 2>&1 )
}

# packed store of an xmm register into a stack slot == accumulator spill/reload
spill_re='v?movu(ps|pd)[[:space:]]+%xmm[0-9]+,[^,]*\((%rsp|%rbp)\)'

rc=0

# ---- 1. register-resident accumulator (single, SSE) ----
compile ks.pp -Cfsse64
s="$tmp/ks.s"
sse_addps=$(grep -cE '(^|[^v])addps' "$s" || true)
sse_spill=$(grep -cE "$spill_re" "$s" || true)
echo "SSE64  sum+dot : addps=$sse_addps  acc-spill-to-stack=$sse_spill (must be 0)"
[ "$sse_addps" -ge 1 ] || { echo "FAIL: expected a packed addps (reduction not vectorized?)"; rc=1; }
[ "$sse_spill" -eq 0 ] || { echo "FAIL: packed accumulator spilled/reloaded to a stack slot (not register-resident)"; rc=1; }

# ---- 2a. SSE dot: mul+add, no FMA ----
sse_mulps=$(grep -cE '(^|[^v])mulps' "$s" || true)
sse_fma=$(grep -cE 'vfmadd231ps' "$s" || true)
echo "SSE64  dot     : mulps=$sse_mulps  vfmadd231ps=$sse_fma (must be 0)"
[ "$sse_mulps" -ge 1 ] || { echo "FAIL: expected mulps for the SSE dot product"; rc=1; }
[ "$sse_fma" -eq 0 ]   || { echo "FAIL: emitted vfmadd on a non-FMA (SSE) target"; rc=1; }

# ---- 2b. AVX-without-FMA dot: vmul+vadd, no FMA ----
compile ks.pp -Cfavx
s="$tmp/ks.s"
avx_vmulps=$(grep -cE 'vmulps' "$s" || true)
avx_vaddps=$(grep -cE 'vaddps' "$s" || true)
avx_fma=$(grep -cE 'vfmadd231ps' "$s" || true)
avx_spill=$(grep -cE "$spill_re" "$s" || true)
echo "AVX    dot     : vmulps=$avx_vmulps vaddps=$avx_vaddps vfmadd231ps=$avx_fma (must be 0)  acc-spill=$avx_spill (must be 0)"
[ "$avx_vmulps" -ge 1 ] || { echo "FAIL: expected vmulps for AVX-without-FMA dot product"; rc=1; }
[ "$avx_vaddps" -ge 1 ] || { echo "FAIL: expected vaddps for AVX-without-FMA dot product"; rc=1; }
[ "$avx_fma" -eq 0 ]    || { echo "FAIL: emitted vfmadd on an AVX-without-FMA target"; rc=1; }
[ "$avx_spill" -eq 0 ]  || { echo "FAIL: packed accumulator spilled to a stack slot on AVX"; rc=1; }

# ---- 2c. AVX2 (FMA) single dot: fused vfmadd231ps, no separate mul ----
compile ks.pp -Cfavx2
s="$tmp/ks.s"
fma_s=$(grep -cE 'vfmadd231ps' "$s" || true)
mul_s=$(grep -cE 'vmulps' "$s" || true)
spill_s=$(grep -cE "$spill_re" "$s" || true)
echo "AVX2   dot(s)  : vfmadd231ps=$fma_s (>=1)  vmulps=$mul_s (must be 0)  acc-spill=$spill_s (must be 0)"
[ "$fma_s" -ge 1 ]   || { echo "FAIL: expected packed vfmadd231ps under -Cfavx2 fast-math"; rc=1; }
[ "$mul_s" -eq 0 ]   || { echo "FAIL: a separate vmulps survived the FMA fusion"; rc=1; }
[ "$spill_s" -eq 0 ] || { echo "FAIL: packed accumulator spilled to a stack slot on AVX2"; rc=1; }

# ---- 2d. AVX2 (FMA) double dot: fused vfmadd231pd ----
compile kd.pp -Cfavx2
s="$tmp/kd.s"
fma_d=$(grep -cE 'vfmadd231pd' "$s" || true)
mul_d=$(grep -cE 'vmulpd' "$s" || true)
echo "AVX2   dot(d)  : vfmadd231pd=$fma_d (>=1)  vmulpd=$mul_d (must be 0)"
[ "$fma_d" -ge 1 ] || { echo "FAIL: expected packed vfmadd231pd under -Cfavx2 fast-math"; rc=1; }
[ "$mul_d" -eq 0 ] || { echo "FAIL: a separate vmulpd survived the double FMA fusion"; rc=1; }

[ "$rc" -eq 0 ] && echo "PASS: reduction accumulator is register-resident; packed FMA fires only under the fast-math+FMA gate"
exit "$rc"
