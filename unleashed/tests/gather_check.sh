#!/usr/bin/env bash
#
# -OoGATHER codegen assertions (AVX2 gather vectorization for indexed loads).
#
# The single-precision indexed sum reduction
#     s := s + a[idx[i]]      (a : array of single ; idx : array of longint)
# reads a through a computed int32 index that is NOT unit-stride across the
# vectorized dimension, so a plain vmovups cannot widen it.  -OoGATHER widens
# the indexed load with the AVX2 gather instruction:
#   * the VF consecutive int32 indices idx[i..i+VF-1] are loaded contiguously
#     (vmovdqu),
#   * an all-ones mask is re-materialised each iteration with vpcmpeqd (the
#     gather clobbers its mask register),
#   * vgatherdps reads a[idx[i..i+VF-1]] lane-by-lane into a packed register
#     that is added into the register-resident float partial sum.
#
# Asserts:
#   1. WITH -OoGATHER on an AVX2 target the loop emits vgatherdps (128-bit xmm
#      VF=4 baseline; 256-bit ymm VF=8 under -OoVECT256).
#   2. WITHOUT -OoGATHER (default / -OoNOGATHER) the loop stays scalar / plain
#      reduction: no vgatherdps.
#   3. Declines that MUST stay scalar even with -OoGATHER: no AVX2 target
#      (-Cfsse64, there is no SSE gather), in-source range checking ({$R+}),
#      disabled fast-math (-OoNOFASTMATH), a double-precision gather, and a
#      contiguous (unit-stride) a[i] reduction (that is the ordinary packed
#      reduction, not a gather).
#
# Usage: unleashed/tests/gather_check.sh [path-to-ppcx64]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# indexed-gather single reduction (the only loop in the file, so a whole-file
# grep is unambiguous)
cat > "$tmp/kg.pp" <<'EOF'
program kg;
{$mode objfpc}{$H+}{$Q-}{$R-}
type TS = array of single; TI = array of longint;
function gsum(a: TS; idx: TI; n: longint): single;
var i: longint; s: single;
begin s:=0; for i:=0 to n-1 do s:=s+a[idx[i]]; gsum:=s; end;
var a: TS; idx: TI;
begin SetLength(a,64); SetLength(idx,64); Writeln(gsum(a,idx,64):0:3); end.
EOF

# range-checked variant (in-source {$R+}: the indexed load must keep its check)
cat > "$tmp/kgr.pp" <<'EOF'
program kgr;
{$mode objfpc}{$H+}{$Q+}{$R+}
type TS = array of single; TI = array of longint;
function gsum(a: TS; idx: TI; n: longint): single;
var i: longint; s: single;
begin s:=0; for i:=0 to n-1 do s:=s+a[idx[i]]; gsum:=s; end;
var a: TS; idx: TI;
begin SetLength(a,64); SetLength(idx,64); Writeln(gsum(a,idx,64):0:3); end.
EOF

# double-precision indexed gather: single-only, must decline
cat > "$tmp/kgd.pp" <<'EOF'
program kgd;
{$mode objfpc}{$H+}{$Q-}{$R-}
type TD = array of double; TI = array of longint;
function gsum(a: TD; idx: TI; n: longint): double;
var i: longint; s: double;
begin s:=0; for i:=0 to n-1 do s:=s+a[idx[i]]; gsum:=s; end;
var a: TD; idx: TI;
begin SetLength(a,64); SetLength(idx,64); Writeln(gsum(a,idx,64):0:3); end.
EOF

# contiguous (unit-stride) single reduction: the ordinary packed reduction, NOT
# a gather -- must not emit vgatherdps
cat > "$tmp/kc.pp" <<'EOF'
program kc;
{$mode objfpc}{$H+}{$Q-}{$R-}
type TS = array of single;
function csum(a: TS; n: longint): single;
var i: longint; s: single;
begin s:=0; for i:=0 to n-1 do s:=s+a[i]; csum:=s; end;
var a: TS;
begin SetLength(a,64); Writeln(csum(a,64):0:3); end.
EOF

compile() { # $1=src ; rest=flags -> writes ${src%.pp}.s in $tmp
  local src="$1"; shift
  ( cd "$tmp" && "$CC" -Fu"$RTL" -O4 "$@" -al -s "$src" >/dev/null 2>&1 )
}

rc=0

# ---- 1. AVX2 baseline WITH -OoGATHER: xmm gather (VF=4) ----
compile kg.pp -OoGATHER -Cfavx2
s="$tmp/kg.s"
g_xmm=$(grep -cE 'vgatherdps[[:space:]]+%xmm' "$s" || true)
echo "AVX2   gather xmm : vgatherdps.xmm=$g_xmm (must be >=1)"
[ "$g_xmm" -ge 1 ] || { echo "FAIL: expected xmm vgatherdps with -OoGATHER on AVX2"; rc=1; }

# ---- 2. AVX2 + VECT256: ymm gather (VF=8) ----
compile kg.pp -OoGATHER -OoVECT256 -Cfavx2
s="$tmp/kg.s"
g_ymm=$(grep -cE 'vgatherdps[[:space:]]+%ymm' "$s" || true)
echo "AVX2   gather ymm : vgatherdps.ymm=$g_ymm (must be >=1)"
[ "$g_ymm" -ge 1 ] || { echo "FAIL: expected ymm vgatherdps with -OoGATHER -OoVECT256 on AVX2"; rc=1; }

# ---- 3. WITHOUT the switch (-OoNOGATHER) stays scalar ----
compile kg.pp -OoNOGATHER -Cfavx2
g=$(grep -cE 'vgatherdps' "$tmp/kg.s" || true)
echo "AVX2   NOGATHER   : vgatherdps=$g (must be 0)"
[ "$g" -eq 0 ] || { echo "FAIL: -OoNOGATHER did not disable the transform"; rc=1; }

# ---- 4. no AVX2 target: there is no SSE gather, must stay scalar ----
compile kg.pp -OoGATHER -Cfsse64
g=$(grep -cE 'gatherdps' "$tmp/kg.s" || true)
echo "SSE64  gather     : gatherdps=$g (must be 0)"
[ "$g" -eq 0 ] || { echo "FAIL: emitted a gather on a non-AVX2 target"; rc=1; }

# ---- 5. in-source range checking ({$R+}) must refuse ----
compile kgr.pp -OoGATHER -Cfavx2
g=$(grep -cE 'vgatherdps' "$tmp/kgr.s" || true)
echo "R+     gather     : vgatherdps=$g (must be 0)"
[ "$g" -eq 0 ] || { echo "FAIL: gather fired under range checking (would read OOB where scalar raises)"; rc=1; }

# ---- 6. disabled fast-math must refuse (FP partial-sum reorder needs it) ----
compile kg.pp -OoGATHER -OoNOFASTMATH -Cfavx2
g=$(grep -cE 'vgatherdps' "$tmp/kg.s" || true)
echo "NOFASTMATH gather : vgatherdps=$g (must be 0)"
[ "$g" -eq 0 ] || { echo "FAIL: gather fired without fast-math"; rc=1; }

# ---- 7. double-precision gather must decline (single-only first landing) ----
compile kgd.pp -OoGATHER -Cfavx2
g=$(grep -cE 'gatherd' "$tmp/kgd.s" || true)
echo "double gather     : gatherd*=$g (must be 0)"
[ "$g" -eq 0 ] || { echo "FAIL: gather wrongly took a double-precision indexed load"; rc=1; }

# ---- 8. contiguous unit-stride reduction is NOT a gather ----
compile kc.pp -OoGATHER -Cfavx2
g=$(grep -cE 'vgatherdps' "$tmp/kc.s" || true)
echo "contig reduction  : vgatherdps=$g (must be 0)"
[ "$g" -eq 0 ] || { echo "FAIL: emitted a gather for a contiguous unit-stride reduction"; rc=1; }

if [ "$rc" -eq 0 ]; then
  echo "gather_check: PASS"
else
  echo "gather_check: FAIL"
fi
exit "$rc"
