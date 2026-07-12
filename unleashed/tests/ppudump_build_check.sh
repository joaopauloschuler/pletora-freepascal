#!/usr/bin/env bash
# Build-and-dump check for the standalone `ppudump` PPU inspector
# (compiler/utils/ppuutils/ppudump.pp).
#
# BACKGROUND / DIAGNOSIS
# ----------------------
# ppudump is *only* ever built through its GENERIC_CPU path: the whole point of
# the tool is that a single binary can decode a .ppu produced for ANY target,
# so the utils Makefile always compiles it (and the `ppu` unit it shares with
# the compiler) with `-dGENERIC_CPU -Fu../generic`.
#
# Under GENERIC_CPU the per-target address size is looked up at run time from
# `CpuAddrBitSize[cpu]`, a table that entfile.pas exposes ONLY inside
# `{$ifdef generic_cpu}` (it mirrors the `tsystemcpu` enum: 26 entries, cpu_no
# .. cpu_loongarch64).  ppudump references `CpuAddrBitSize[cpu]` unconditionally
# (gettokenbufsizeint, ~line 2093), so *without* -dGENERIC_CPU that reference is
# undefined and the tool cannot compile at all -- which is exactly the historical
# "CpuAddrBitSize compile error around line 2093" symptom.  With -dGENERIC_CPU
# (the way the tool is actually built) the table is in scope and the tool builds,
# links and runs.  This check pins that working path down so every PPU-format
# change (currently CurrentPPULongVersion 37) can be verified against a runnable
# ppudump binary.
#
# WHAT THIS CHECKS
# ----------------
#   1. ppudump builds cleanly FROM SCRATCH (every unit recompiled into a private
#      temp -FU dir, so no stale .ppu in the tree is trusted) via the GENERIC_CPU
#      path, and the resulting binary self-reports the current PPU LongVersion.
#   2. That binary decodes a freshly compiled unit's .ppu and prints the shared
#      per-procdef optimizer-summary blob: the optsum_pure, optsum_modref and
#      optsum_deadpara sections, including the per-static mangled-name lists that
#      -OoMODREF serializes (reads_statics[...] / writes_statics[...]).
#
# No binary is left in the source tree: everything lands in a mktemp -d that is
# removed on exit.
#
# Usage: unleashed/tests/ppudump_build_check.sh [path-to-ppcx64]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"
CDIR="$root/compiler"
SRC="$CDIR/utils/ppuutils/ppudump.pp"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

rc=0

[ -x "$CC" ] || { echo "FAIL: compiler not found/executable: $CC"; exit 1; }
[ -f "$SRC" ] || { echo "FAIL: ppudump source not found: $SRC"; exit 1; }

# ---- 1: clean GENERIC_CPU build of ppudump -----------------------------------
# Recompile ppudump *and every unit it uses* into the private temp unit dir
# ($tmp/units), so this is a genuine from-scratch build that never depends on a
# stale .ppu already sitting in the tree.  This mirrors the utils Makefile's
# recipe (`-Fu../llvm -Fu../generic -dGENERIC_CPU`).
mkdir -p "$tmp/units"
build_log="$tmp/build.log"
if ! "$CC" \
      -Fu"$CDIR" -Fu"$CDIR/utils" -Fu"$CDIR/llvm" -Fu"$CDIR/generic" -Fu"$RTL" \
      -Fi"$CDIR" -Fi"$CDIR/utils" \
      -dGENERIC_CPU -FU"$tmp/units" -o"$tmp/ppudump" "$SRC" >"$build_log" 2>&1; then
  echo "FAIL: ppudump GENERIC_CPU build failed"
  grep -iE 'error|fatal' "$build_log" | head -20
  exit 1
fi
[ -x "$tmp/ppudump" ] || { echo "FAIL: ppudump binary not produced"; exit 1; }
echo "build: ppudump built cleanly via GENERIC_CPU ($(grep -oE '[0-9]+ lines compiled' "$build_log" | tail -1))"

# ---- 2: dump a unit that carries all three optimizer summaries ---------------
cat > "$tmp/optu.pas" <<'EOF'
unit optu;
{$mode objfpc}
interface
function AddPure(a, b: longint): longint;   { PURE/const, no memory }
function ReadG: longint;                     { reads two statics       }
procedure WriteG(v: longint);                { reads+writes statics    }
function DeadP(a, b, c: longint): longint;   { b is a dead parameter   }
implementation
var gcounter: longint = 0;
    gtotal:   longint = 0;
function AddPure(a, b: longint): longint;
begin AddPure := a + b; end;
function ReadG: longint;
begin ReadG := gcounter + gtotal; end;
procedure WriteG(v: longint);
begin gcounter := v; gtotal := gtotal + v; end;
function DeadP(a, b, c: longint): longint;
begin DeadP := a + c; end;   { b never read -> ref_mask bit 1 clear }
end.
EOF

if ! "$CC" -Fu"$RTL" -O3 -OoPURE -OoMODREF -OoDEADPARA \
      -FU"$tmp" -FE"$tmp" "$tmp/optu.pas" >"$tmp/compunit.log" 2>&1; then
  echo "FAIL: could not compile the optsum test unit"
  grep -iE 'error|fatal' "$tmp/compunit.log" | head
  exit 1
fi
[ -f "$tmp/optu.ppu" ] || { echo "FAIL: optu.ppu not produced"; exit 1; }

dump="$tmp/dump.txt"
(ulimit -v 3000000; timeout 60 "$tmp/ppudump" "$tmp/optu.ppu") >"$dump" 2>&1 \
  || { echo "FAIL: ppudump crashed while dumping optu.ppu"; tail -5 "$dump"; exit 1; }

# sanity: the built binary decodes the CURRENT on-disk PPU format.
lv="$(grep -oE 'LongVersion: [0-9]+' "$dump" | grep -oE '[0-9]+' | head -1 || true)"
want="$(grep -oE 'CurrentPPULongVersion *= *[0-9]+' "$CDIR/ppu.pas" | grep -oE '[0-9]+' | head -1)"
echo "dump: ppudump LongVersion=${lv:-<none>} ; source CurrentPPULongVersion=$want"
[ -n "$lv" ] && [ "$lv" = "$want" ] \
  || { echo "FAIL: dumped LongVersion ($lv) != source CurrentPPULongVersion ($want)"; rc=1; }

check() { # <label> <grep-args...>
  local label="$1"; shift
  if grep -qE "$@" "$dump"; then
    echo "  ok: $label"
  else
    echo "  FAIL: missing $label"; rc=1
  fi
}

echo "dump: optimizer-summary sections in optu.ppu --"
check "optsum_pure section"        'Optimizer summary : PURE .*is_pure=1'
check "optsum_modref section"      'Optimizer summary : MODREF .*reads='
check "optsum_deadpara section"    'Optimizer summary : DEADPARA .*ref_mask=\$'
# per-static mangled-name lists (the -OoMODREF serialization) -- WriteG must list
# both statics it writes; the mangled names carry the OPTU unit prefix.
check "modref reads_statics list"  'reads_statics\[[1-9]'
check "modref writes_statics list" 'writes_statics\[[1-9]'
check "per-static mangled name"    'TC_\$OPTU_\$\$_GTOTAL'
# DeadP's dead middle parameter (b) must show a cleared bit: ref_mask=...5 (a,c).
check "dead-parameter mask (b clear)" 'DEADPARA  ref_mask=\$0*5\b'

if [ "$rc" -eq 0 ]; then
  echo "PASS: ppudump builds via GENERIC_CPU and dumps optsum_pure/optsum_modref/optsum_deadpara (with per-static lists)"
fi
exit "$rc"
