#!/usr/bin/env bash
# Group-ablation speedup matrix for the -O4 default optimizer set: measure
# what each functional GROUP of passes contributes to -O4, then (drill mode)
# what each pass contributes within its group.
#
# Stage 1 (default) -- per group G:
#     A = -O4                 (everything on)
#     B = -O4 -OoNOP ...      (every pass of G turned off, the rest still on)
# A speedup < 1.00x on some fixture means removing G costs performance there,
# i.e. the group earns its place.  Unlike single-pass leave-one-out this is
# robust to redundancy WITHIN a group (two overlapping passes can cover for
# each other one at a time, but not when the whole group is removed), and it
# measures enabler analyses (MODREF/PURE/IPARA) with their consumers running.
#
# A NULL row (B identical to A) always runs first: its spread is the noise
# floor of this machine/run -- treat any group effect inside it as unreadable.
#
# Stage 2 (DRILL=1) -- per pass P of the named group(s):
#     A = -O4
#     B = -O4 -OoNOP          (single-pass leave-one-out)
# Run it on the groups stage 1 showed a hit for, to attribute the group's
# effect to individual passes (redundant pairs inside the group can still
# mask each other here -- if a group hit vanishes when drilled, suspect
# overlap and try removing pass pairs by hand with pf-bench ab).
#
# Stage 3 (manual) -- verify the surviving set S reproduces the -O3 -> -O4
# gap constructively:
#     unleashed/tools/pf-bench/bin/pf-bench ab --root unleashed/tests \
#         --compiler-a ./fpcu.sh --compiler-b ./fpcu.sh \
#         --flags="-O3" --flags-b="-OoP1 -OoP2 ..." --runs 4 --warmup 1
#
# Same harness and gating as o4_pass_speedup_bench.sh: bench/*.bench.lpr
# fixtures under unleashed/tests, ABAB-interleaved, checksum-gated (a
# miscompile voids the row, it cannot win it).  Overrides:
#   PF_BENCH_BIN     path to the pf-bench binary
#   PF_BENCH_ROOT    root directory pf-bench scans for bench/*.bench.lpr
#   PF_BENCH_GROUPS  subset of group names to run (e.g. "loopnest vector");
#                    with DRILL=1, the group(s) whose passes to drill into
#   PF_BENCH_FILTER  substring filter on benchmark names (pf-bench --filter)
#   PF_BENCH_RUNS    timed runs per side (default 4)
#   PF_BENCH_CPU     pin timed runs to these CPUs via taskset (recommended on
#                    hybrid P/E-core machines, e.g. PF_BENCH_CPU=0)
#   PF_BENCH_SCALE   divide fixture repetition counts (fast triage: SCALE=4)
#   DRILL=1          stage 2: leave-one-out per pass within PF_BENCH_GROUPS
#
# Usage: unleashed/tests/o4_group_ablation_bench.sh OUTPUT_DIR [compiler]
#   [compiler] defaults to <repo>/fpcu.sh; a bare ppcx64 also works (unit
#   paths for the fixtures' packages are appended automatically).
# Output: OUTPUT_DIR/matrix.tsv (group-or-pass, benchmark, speedup, status)
# + per-unit logs with the full pf-bench tables + progress.log.
# Stage 1 over 7 groups + NULL is ~8 pf-bench runs (vs 39 for the per-pass
# matrices): roughly 25 minutes at default scale.
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

# fpcu.sh supplies the RTL + packages unit paths itself; a bare compiler
# (e.g. compiler/ppcx64 passed as $2) needs them appended explicitly or every
# fixture build fails with "Can't find unit".
case "$CC" in
  *fpcu.sh) UNITPATHS="" ;;
  *) UNITPATHS=" -Fu$root/rtl/units/x86_64-linux -Fu$root/packages/*/units/x86_64-linux" ;;
esac

# The in-repo pf-bench harness; build it on first use.
PB="${PF_BENCH_BIN:-$root/unleashed/tools/pf-bench/bin/pf-bench}"
if [ ! -x "$PB" ]; then
  echo "pf-bench not built; building..."
  "$root/unleashed/tools/pf-bench/build.sh" || exit 1
fi
[ -x "$PB" ] || { echo "ERROR: pf-bench not found at $PB (set PF_BENCH_BIN)"; exit 1; }

PBROOT="${PF_BENCH_ROOT:-$here}"
RUNS="${PF_BENCH_RUNS:-4}"
FILTER="${PF_BENCH_FILTER:-}"
FILTERARGS=()
[ -n "$FILTER" ] && FILTERARGS=(--filter "$FILTER")
mkdir -p "$OUT"

# The functional groups of genericlevel4optimizerswitches (globtype.pas).
# The grouping is a hypothesis about which passes cooperate -- it is data,
# keep it versioned here.  Every toggleable -O4 pass appears exactly once.
GROUPDEFS="
loopnest:LOOPINTERCHANGE LOOPTILE LOOPFUSE LOOPDISTPAT LOOPPEEL LOOPSPLIT LOOPUNSWITCH UNROLLJAM PREDCOM LICM FINALVALUE
vector:VECTORIZE FASTMATH REASSOC IFCONVERT INT8DOT
enablers:MODREF PURE IPARA
scalar:SRA DEADVALUES VRP RANGEELIM GVNPRE REE SINK STOREMOTION STOREMERGE BITIDIOM
branch:JUMPTHREAD CASECLUSTER SWITCHTABLE CROSSJUMP BLOCKORDER
ipo:DEVIRT DEADPARA SIBCALL SHRINKWRAP
misc:ORDERFIELDS
"

group_passes() {  # group_passes NAME -> pass list on stdout, empty if unknown
  echo "$GROUPDEFS" | awk -F: -v g="$1" '$1 == g { print $2 }'
}

all_group_names() { echo "$GROUPDEFS" | awk -F: 'NF { print $1 }'; }

GROUPS_SEL="${PF_BENCH_GROUPS:-$(all_group_names | tr '\n' ' ')}"
for g in $GROUPS_SEL; do
  [ -n "$(group_passes "$g")" ] || { echo "ERROR: unknown group '$g' (known: $(all_group_names | tr '\n' ' '))"; exit 1; }
done

# Build the work list: "UNIT<TAB>flags-b".  Stage 1 removes whole groups;
# DRILL=1 removes one pass at a time from the selected groups.  The NULL row
# (empty flags-b: B identical to A) always runs first as the noise floor.
UNITS="NULL"$'\t'$'\n'
if [ "${DRILL:-0}" = "1" ]; then
  for g in $GROUPS_SEL; do
    for p in $(group_passes "$g"); do
      UNITS+="$p"$'\t'"-OoNO$p"$'\n'
    done
  done
else
  for g in $GROUPS_SEL; do
    fb=""
    for p in $(group_passes "$g"); do fb+=" -OoNO$p"; done
    UNITS+="$g"$'\t'"${fb# }"$'\n'
  done
fi

total=$(printf '%s' "$UNITS" | grep -c .)
export PF_BENCH_SCALE="${PF_BENCH_SCALE:-2}"
echo -e "unit\tbenchmark\tspeedup\tstatus" > "$OUT/matrix.tsv"
n=0
while IFS=$'\t' read -r u fb; do
  [ -n "$u" ] || continue
  n=$((n+1))
  echo "[$n/$total] $u  $(date +%H:%M:%S)" | tee -a "$OUT/progress.log"
  "$PB" ab --root "$PBROOT" "${FILTERARGS[@]}" \
      --compiler-a "$CC" --compiler-b "$CC" \
      --flags="-O4$UNITPATHS" ${fb:+--flags-b="$fb"} \
      --runs "$RUNS" --warmup 1 > "$OUT/$u.log" 2>&1
  # pf-bench table rows: "<proj>/<bench>  <A median>  <B median>  <spd>x  <status>"
  # where status is "ok", "run failure" or "CHECKSUM MISMATCH (...)".
  awk -v U="$u" '$1 ~ /\// && ($4 ~ /x$/ || $4 == "n/a") {
      st = ($5 == "ok") ? "ok" : "void";
      print U "\t" $1 "\t" $4 "\t" st }' \
      "$OUT/$u.log" >> "$OUT/matrix.tsv"
done <<< "$UNITS"
echo "DONE $(date +%H:%M:%S)" | tee -a "$OUT/progress.log"
echo "matrix: $OUT/matrix.tsv"
echo "Reading: NULL rows = noise floor.  A group row BELOW the floor means"
echo "removing that group hurts, i.e. it earns its place in -O4."
