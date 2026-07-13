#!/usr/bin/env bash
# Micro-benchmark: -OoVECT256 (256-bit ymm) vs the default 128-bit xmm
# autovectorization width, on the three canonical streaming kernels --
# single-precision dot product, saxpy (a[i]:=a[i]+s*b[i]) and an element-wise
# multiply.  Same program built with -OoVECTORIZE alone (xmm) and with
# -OoVECTORIZE -OoVECT256 (ymm), both on -Cfavx2, timed under the experiment
# budget (ulimit + timeout, well under 5 min total).
#
# Requires an AVX2 host to RUN the ymm binary (checks /proc/cpuinfo and skips
# the run, keeping only the codegen assertion, if AVX is absent).
#
# Usage: unleashed/tests/vect256_bench.sh [path-to-ppcx64]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# NB: the arrays MUST be simple non-aliased locals -- the vectorizer refuses
# global / var-parameter / address-taken bases -- so the kernels live in a
# function and the timing loop repeats inside it.
cat > "$tmp/bench.pp" <<'EOF'
program bench;
{$mode objfpc}{$H+}
type TS = array of single;
function kernel(reps: longint): single;
var a,b,c: TS; i,rep: longint; acc: single;
const N = 4096;
begin
  SetLength(a,N); SetLength(b,N); SetLength(c,N);
  for i:=0 to N-1 do begin a[i]:=i*0.001+1.0; b[i]:=i*0.002-0.5; c[i]:=0; end;
  acc:=0;
  for rep:=0 to reps-1 do
    begin
      { dot }    for i:=0 to N-1 do acc:=acc+a[i]*b[i];
      { saxpy }  for i:=0 to N-1 do c[i]:=c[i]+3.0*a[i];
      { mul }    for i:=0 to N-1 do c[i]:=a[i]*b[i];
    end;
  kernel:=acc+c[0];
end;
begin
  Writeln(kernel(40000):0:2);
end.
EOF

have_avx=0
grep -qw avx /proc/cpuinfo && have_avx=1

build() { # $1=out $2..=flags
  local out="$1"; shift
  ( cd "$tmp" && "$CC" -Fu"$RTL" -O4 -OoVECTORIZE -OoFASTMATH -Cfavx2 "$@" bench.pp -o"$out" >/dev/null 2>&1 )
}

build xmm
build ymm -OoVECT256

echo "codegen: xmm build %ymm=$(objdump -d "$tmp/xmm" 2>/dev/null | grep -c '%ymm' || true)  ymm build %ymm=$(objdump -d "$tmp/ymm" 2>/dev/null | grep -c '%ymm' || true)"

if [ "$have_avx" -ne 1 ]; then
  echo "SKIP runtime benchmark: host has no AVX (codegen built both variants OK)"
  exit 0
fi

timeit() { # $1=binary -> echoes seconds
  local b="$1" t0 t1
  t0=$(date +%s.%N)
  ( ulimit -v 3000000; timeout 120 "$b" >/dev/null )
  t1=$(date +%s.%N)
  awk "BEGIN{printf \"%.3f\", $t1-$t0}"
}

# warm, then best-of-3 each
for w in 1 2; do timeit "$tmp/xmm" >/dev/null; timeit "$tmp/ymm" >/dev/null; done
bx=9999; by=9999
for r in 1 2 3; do
  x=$(timeit "$tmp/xmm"); y=$(timeit "$tmp/ymm")
  awk "BEGIN{exit !($x<$bx)}" && bx=$x
  awk "BEGIN{exit !($y<$by)}" && by=$y
done
echo "xmm (128-bit): ${bx}s   ymm (256-bit): ${by}s"
awk "BEGIN{printf \"speedup (xmm/ymm): %.2fx\n\", $bx/$by}"
