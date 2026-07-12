#!/usr/bin/env bash
# Per-pass speedup matrix for the -O4 default optimizer set ("leave-one-in"):
# for every custom pass P that -O4 enables, benchmark
#
#     A = -O3                (baseline: NO custom -Oo passes)
#     B = -O3 -OoP           (exactly one pass left in)
#
# over every bench/*.bench.lpr fixture pf-bench discovers, ABAB-interleaved and
# checksum-gated (a pass that miscompiles fails the row, it cannot "win" it).
# The result is a pass x benchmark table of each pass's STANDALONE speedup --
# complementary to a leave-one-out ablation (-O4 vs -O4 -OoNOP), which measures
# a pass's marginal value with all the others still on.
#
# NOTE: MODREF / PURE / IPARA are enabler ANALYSES -- alone atop -O3 they
# measure ~1.00x by construction (their consumers are off); their honest
# metric is the leave-one-out form.
#
# Requires the pf-bench harness from the enclosing monorepo (not shipped with
# this repository).  Auto-detected when this checkout lives at
# <monorepo>/pletora/freepascal; override with:
#   PF_BENCH_BIN   path to the pf-bench binary
#   PF_BENCH_ROOT  root directory pf-bench scans for bench/*.bench.lpr
#
# Usage: unleashed/tests/o4_pass_speedup_bench.sh OUTPUT_DIR [path-to-ppcx64]
# Output: OUTPUT_DIR/matrix.tsv (pass, benchmark, speedup, status) + per-pass
# logs with the full pf-bench tables.  Takes a few hours: 39 passes x every
# fixture x (1 warmup + 4 timed runs) x 2 sides.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${2:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"
PB="${PF_BENCH_BIN:-$root/../../fantastica/pf-bench/bin/pf-bench}"
PBROOT="${PF_BENCH_ROOT:-$(cd "$root/../.." 2>/dev/null && pwd)}"
OUT="${1:?usage: $0 OUTPUT_DIR [path-to-ppcx64]}"

[ -x "$PB" ] || { echo "ERROR: pf-bench not found at $PB (set PF_BENCH_BIN)"; exit 1; }
[ -x "$CC" ] || { echo "ERROR: compiler not found at $CC"; exit 1; }
mkdir -p "$OUT"

# The toggleable members of genericlevel4optimizerswitches (globtype.pas):
# the long-standing 32 plus the 2026-07 promotions
# (MODREF PURE IPARA SIBCALL GVNPRE SHRINKWRAP FINALVALUE).
PASSES="ORDERFIELDS DEADVALUES FASTMATH LICM LOOPUNSWITCH BITIDIOM RANGEELIM
JUMPTHREAD LOOPDISTPAT LOOPPEEL LOOPSPLIT LOOPFUSE IFCONVERT REASSOC UNROLLJAM
PREDCOM SRA STOREMERGE CASECLUSTER CROSSJUMP BLOCKORDER SINK STOREMOTION VRP
SWITCHTABLE REE VECTORIZE DEVIRT DEADPARA INT8DOT LOOPINTERCHANGE LOOPTILE
MODREF PURE IPARA SIBCALL GVNPRE SHRINKWRAP FINALVALUE"

total=$(echo $PASSES | wc -w)
export PF_BENCH_SCALE="${PF_BENCH_SCALE:-2}"
echo -e "pass\tbenchmark\tspeedup\tstatus" > "$OUT/matrix.tsv"
n=0
for p in $PASSES; do
  n=$((n+1))
  echo "[$n/$total] $p  $(date +%H:%M:%S)" | tee -a "$OUT/progress.log"
  "$PB" ab --root "$PBROOT" \
      --compiler-a "$CC" --compiler-b "$CC" \
      --flags="-Fu$RTL -O3" --flags-b="-Oo$p" \
      --runs 4 --warmup 1 > "$OUT/$p.log" 2>&1
  # pf-bench table rows: "<proj>/<bench>  <A median>  <B median>  <spd>x  <status>"
  awk -v P="$p" '/x  *(ok|void)/ {print P "\t" $1 "\t" $(NF-1) "\t" $NF}' \
      "$OUT/$p.log" >> "$OUT/matrix.tsv"
done
echo "DONE $(date +%H:%M:%S)" | tee -a "$OUT/progress.log"
echo "matrix: $OUT/matrix.tsv"
