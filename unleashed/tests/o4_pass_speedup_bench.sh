#!/usr/bin/env bash
# Per-pass speedup matrix for the -O4 default optimizer set ("leave-one-in"):
# for every custom pass P that -O4 enables, benchmark
#
#     A = -O3                (baseline: NO custom -Oo passes)
#     B = -O3 -OoP           (exactly one pass left in)
#
# over every bench/*.bench.lpr fixture pf-bench discovers under
# unleashed/tests/bench, ABAB-interleaved and checksum-gated (a pass that
# miscompiles fails the row, it cannot "win" it).  The result is a
# pass x benchmark table of each pass's STANDALONE speedup -- complementary to
# a leave-one-out ablation (-O4 vs -O4 -OoNOP), which measures a pass's
# marginal value with all the others still on.
#
# NOTE: MODREF / PURE / IPARA are enabler ANALYSES -- alone atop -O3 they
# measure ~1.00x by construction (their consumers are off); their honest
# metric is the leave-one-out form.
#
# Self-contained: uses the in-repo pf-bench harness (unleashed/tools/pf-bench,
# built automatically on first use) and the in-repo fixtures.  The compiler is
# invoked through fpcu.sh, which supplies the RTL + packages unit paths -- the
# compiler, RTL and packages must be built (./rebuildu.sh).  Overrides:
#   PF_BENCH_BIN    path to the pf-bench binary
#   PF_BENCH_ROOT   root directory pf-bench scans for bench/*.bench.lpr
#   PF_BENCH_PASSES subset of passes to run (e.g. "LICM VRP")
#   PF_BENCH_CPU    pin timed runs to these CPUs via taskset (recommended on
#                   hybrid P/E-core machines, e.g. PF_BENCH_CPU=0)
#
# Usage: unleashed/tests/o4_pass_speedup_bench.sh OUTPUT_DIR [compiler]
#   [compiler] defaults to <repo>/fpcu.sh; a bare ppcx64 also works but then
#   the fixtures' package units (paszlib, regexpr, fcl-hash) must be reachable
#   some other way -- prefer the wrapper.
# Output: OUTPUT_DIR/matrix.tsv (pass, benchmark, speedup, status) + per-pass
# logs with the full pf-bench tables.  Takes a few hours: 39 passes x every
# fixture x (1 warmup + 4 timed runs) x 2 sides.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
OUT="${1:?usage: $0 OUTPUT_DIR [compiler]}"

# Compiler auto-detection: explicit arg > $FPCU env > repo fpcu.sh.  A system
# fpc is NOT an acceptable fallback -- stock fpc rejects the fork's -Oo pass
# names, so every row would be a build failure.
CC="${2:-${FPCU:-$root/fpcu.sh}}"
[ -x "$CC" ] || { echo "ERROR: compiler not found at $CC"; exit 1; }
[ -x "$root/compiler/ppcx64" ] || { echo "ERROR: in-tree compiler not built (run ./rebuildu.sh)"; exit 1; }

# The in-repo pf-bench harness; build it on first use.
PB="${PF_BENCH_BIN:-$root/unleashed/tools/pf-bench/bin/pf-bench}"
if [ ! -x "$PB" ]; then
  echo "pf-bench not built; building..."
  "$root/unleashed/tools/pf-bench/build.sh" || exit 1
fi
[ -x "$PB" ] || { echo "ERROR: pf-bench not found at $PB (set PF_BENCH_BIN)"; exit 1; }

PBROOT="${PF_BENCH_ROOT:-$here}"
mkdir -p "$OUT"

# The toggleable members of genericlevel4optimizerswitches (globtype.pas):
# the long-standing 32 plus the 2026-07 promotions
# (MODREF PURE IPARA SIBCALL GVNPRE SHRINKWRAP FINALVALUE).
# Override with PF_BENCH_PASSES="LICM VRP" for a partial run.
PASSES="${PF_BENCH_PASSES:-ORDERFIELDS DEADVALUES FASTMATH LICM LOOPUNSWITCH BITIDIOM RANGEELIM
JUMPTHREAD LOOPDISTPAT LOOPPEEL LOOPSPLIT LOOPFUSE IFCONVERT REASSOC UNROLLJAM
PREDCOM SRA STOREMERGE CASECLUSTER CROSSJUMP BLOCKORDER SINK STOREMOTION VRP
SWITCHTABLE REE VECTORIZE DEVIRT DEADPARA INT8DOT LOOPINTERCHANGE LOOPTILE
MODREF PURE IPARA SIBCALL GVNPRE SHRINKWRAP FINALVALUE}"

total=$(echo $PASSES | wc -w)
export PF_BENCH_SCALE="${PF_BENCH_SCALE:-2}"
echo -e "pass\tbenchmark\tspeedup\tstatus" > "$OUT/matrix.tsv"
n=0
for p in $PASSES; do
  n=$((n+1))
  echo "[$n/$total] $p  $(date +%H:%M:%S)" | tee -a "$OUT/progress.log"
  "$PB" ab --root "$PBROOT" \
      --compiler-a "$CC" --compiler-b "$CC" \
      --flags=-O3 --flags-b="-Oo$p" \
      --runs 4 --warmup 1 > "$OUT/$p.log" 2>&1
  # pf-bench table rows: "<proj>/<bench>  <A median>  <B median>  <spd>x  <status>"
  # where status is "ok", "run failure" or "CHECKSUM MISMATCH (...)".
  awk -v P="$p" '$1 ~ /\// && ($4 ~ /x$/ || $4 == "n/a") {
      st = ($5 == "ok") ? "ok" : "void";
      print P "\t" $1 "\t" $4 "\t" st }' \
      "$OUT/$p.log" >> "$OUT/matrix.tsv"
done
echo "DONE $(date +%H:%M:%S)" | tee -a "$OUT/progress.log"
echo "matrix: $OUT/matrix.tsv"
