#!/bin/sh
# Full rebuild of the in-tree FPC Unleashed toolchain:
#   1. compiler (3-stage cycle, seeded by the system FPC)
#   2. RTL
#   3. packages
#   4. LCL (lclbase.lpk + lcl.lpk), if a sibling ../lazarus checkout exists
# Usage: ./rebuildu.sh [--no-clean-packages]
#   --no-clean-packages  skip "make -C packages clean" before building. By
#                        default packages are cleaned: fpmake's dependency
#                        check never compares against the compiler or RTL, so
#                        without a clean, packages whose sources are unchanged
#                        keep PPUs built by the previous compiler/RTL (stale
#                        codegen, "PPU Invalid Long Version"/checksum errors).
# Environment:
#   SEED=/path/to/ppcXXX  override the auto-detected seed compiler
#   OPT="-O4 ..."         base optimizer flag set threaded through the WHOLE
#                         bootstrap, INCLUDING the seed -> stage-1 compile.  So
#                         it may only contain flags the seed compiler (system
#                         FPC 3.2.2) understands -- standard levels (-O1..-O4),
#                         -Cf*, -Cr, etc.  It must NOT contain fork-only -Oo*
#                         pass names (the seed rejects them): use OPTFORK for
#                         those.  `make cycle OPT="$OPT"` threads OPT into
#                         LOCALOPT+RTLOPT for every cycle stage (OPTLEVEL* are
#                         empty in this tree, so all stages get the SAME base
#                         flags).  Unset => makefile default flags.
#   OPTFORK="-Oo... "     extra flags applied ONLY where the FORK compiler does
#                         the compiling: cycle stages 2/3/4 (via LOCALOPTLEVEL2..4
#                         + RTLOPTLEVEL2..3, which the seed-built stage-1 never
#                         sees) and the standalone RTL/packages rebuilds.  This
#                         is how the opt-in -Oo* passes (REFELIDE, PARTIALINLINE,
#                         STACKALLOC, UNROLLDYN, PREFETCH, ICF, IPARA, SIBCALL,
#                         IPACP, VECT256, and the *NO* switches) get exercised on
#                         the compiler's own source without tripping the seed.
#
#   Because cycle's stage-2 (ppc2) and stage-3 (ppc3) are BOTH built by a
#   fork compiler at OPT+OPTFORK, cycle's own ppc2-vs-ppc3 `next`/DIFF compare is
#   the classic three-stage fixed-point check AT YOUR FLAGS: any miscompile that
#   alters codegen makes the diff fail and aborts the build.
#
#   SELF-HOST GATE (standing regression gate): NO green flag set exists yet
#   (2026-07).  The first self-host attempts caught real -O4 problems -- exactly
#   the payoff of this gate -- both currently OPEN as tasklist follow-ups:
#
#   1. OPT="-O4"  aborts stage-2 on compiler/rgobj.pas:688: a genuine -O4
#      MISCOMPILE.  The -O4 store-sink pass (-OoSINK) interacting with the loop
#      pipeline sinks the unconditional `endspill:=true` re-init of the
#      register-spill `repeat endspill:=true; if ... then endspill:=not
#      spill_registers(...); until endspill;` loop, so `until endspill` re-reads
#      a stale value -> infinite loop; the same restructuring makes the dataflow
#      checker emit a spurious "endspill does not seem to be initialized" warning
#      (treated-as-error -> stage-2 abort).  Reduced reproducer:
#      unleashed/tests/known_miscompiles/o4_sink_repeat_until_01.pp (correct at
#      -O2/-O3 and -O4 -OoNOSINK; infinite loop + warning at plain -O4).
#
#   2. OPT="-O4" OPTFORK="-OoNOSINK"  gets PAST rgobj.pas (proving the OPTFORK
#      level-threading works) but aborts stage-2 on compiler/optfinalvalue.pas:600
#      with another spurious -O4 "Local variable accs does not seem to be
#      initialized" warning-as-error (accs is a local array filled in one for-k
#      loop and read in the next; -O4's DFA is over-conservative).  Context-
#      dependent (needs the full cycle's defines); filed by location.
#
#   So plain -O4 self-host is BLOCKED pending those fixes.  Once green, adopt the
#   winning flag set here as the documented default gate and (optionally) fold in
#   the opt-in -Oo* passes one at a time via OPTFORK.
set -e
FP="$(cd "$(dirname "$0")" && pwd)"

# Base flags (all stages incl. seed); fork-only flags (fork stages + RTL/pkgs).
OPT="${OPT:-}"
OPTFORK="${OPTFORK:-}"
# Flags for the standalone RTL/packages rebuilds, which the FORK compiler runs.
FORKOPT="$(echo "$OPT $OPTFORK" | sed 's/^ *//;s/ *$//')"
if [ -n "$OPT$OPTFORK" ]; then
  echo "rebuildu.sh: self-host flags OPT=\"$OPT\" OPTFORK=\"$OPTFORK\""
fi

# Native compiler binary name and unit directory per host CPU.
case "$(uname -m)" in
  x86_64)        PPC=ppcx64;  CPU=x86_64  ;;
  aarch64|arm64) PPC=ppca64;  CPU=aarch64 ;;
  i?86)          PPC=ppc386;  CPU=i386    ;;
  armv7l|armv6l) PPC=ppcarm;  CPU=arm     ;;
  ppc64le)       PPC=ppcppc64; CPU=powerpc64 ;;
  riscv64)       PPC=ppcrv64; CPU=riscv64 ;;
  *) echo "rebuildu.sh: unsupported host cpu $(uname -m) (set SEED= and edit the case)" >&2
     exit 2 ;;
esac
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
UNITDIR="$CPU-$OS"

# Seed compiler: $SEED if given, else whatever binary the system fpc
# driver would run (fpc -PB prints its full path).
if [ -z "$SEED" ]; then
  if command -v fpc >/dev/null 2>&1; then
    SEED="$(fpc -PB 2>/dev/null || true)"
  fi
fi
if [ -z "$SEED" ] || [ ! -x "$SEED" ]; then
  echo "rebuildu.sh: no seed compiler found (no usable 'fpc' on PATH; set SEED=/path/to/$PPC)" >&2
  exit 2
fi
case "$SEED" in
  "$FP"/*) echo "rebuildu.sh: SEED points inside this tree; 'make clean cycle' would delete it mid-run - use an external compiler" >&2
           exit 2 ;;
esac

# `make cycle OPT=` empties OPT into LOCALOPT/RTLOPT for every stage; empty is
# equivalent to not passing it.  OPTFORK is threaded via the per-CYCLELEVEL
# LOCALOPTLEVEL2..4 / RTLOPTLEVEL2..3 variables so ONLY the fork-built stages
# (ppc2, ppc3, the final ppcx64, and cycle's RTL) receive the fork-only -Oo*
# flags -- the seed that builds stage-1 (CYCLELEVEL 1) never sees them.
echo "=== 1/4 compiler (seed: $SEED, target: $UNITDIR${OPT:+, OPT=$OPT}${OPTFORK:+, OPTFORK=$OPTFORK}) ==="
make -C "$FP/compiler" clean cycle FPC="$SEED" OPT="$OPT" \
     LOCALOPTLEVEL2="$OPTFORK" LOCALOPTLEVEL3="$OPTFORK" LOCALOPTLEVEL4="$OPTFORK" \
     RTLOPTLEVEL2="$OPTFORK" RTLOPTLEVEL3="$OPTFORK"

echo "=== 2/4 rtl ==="
make -C "$FP/rtl" clean all FPC="$FP/compiler/$PPC" OPT="$FORKOPT"

if [ "$1" != "--no-clean-packages" ]; then
  echo "=== packages clean ==="
  make -C "$FP/packages" clean FPC="$FP/compiler/$PPC"
fi

echo "=== 3/4 packages ==="
make -C "$FP" packages FPC="$FP/compiler/$PPC" OPT="$FORKOPT"

# Rebuild the LCL with the freshly built in-tree compiler.
LAZ="${LAZDIR:-$FP/../lazarus}"
if [ -d "$LAZ" ]; then
  if command -v lazbuild >/dev/null 2>&1; then
    echo "=== 4/4 LCL ($LAZ) ==="
    "$FP/lazbuildu.sh" "$LAZ/lcl/lclbase.lpk"
    "$FP/lazbuildu.sh" "$LAZ/lcl/interfaces/lcl.lpk"
  else
    echo "warning: $LAZ exists but no lazbuild on PATH - skipping LCL" >&2
  fi
else
  echo "=== 4/4 LCL skipped (no $LAZ) ==="
fi

# Stale package PPUs copied into rtl/units shadow the package copies and
# break later builds (e.g. "Can't find unit system.timespan"); RTL make
# clean does not remove them, so warn if any are present.
for u in dateutils strutils system.timespan; do
  if [ -f "$FP/rtl/units/$UNITDIR/$u.ppu" ]; then
    echo "warning: stray $u.ppu in rtl/units/$UNITDIR/ - delete it if unit errors appear" >&2
  fi
done

echo "=== done ==="
