#!/usr/bin/env bash
# Remark/gating + bit-exact assertions for the -OoMODREF per-location relaxation
# of the -OoLICM and -OoSINK call-relocation gates (compiler/optloop.pas).
#
# -OoLICM hoists a loop-invariant call into the preheader, and -OoSINK moves a
# pure assignment into the single if-arm that reads it.  For a CALL rhs both used
# to require the strong -OoPURE CONST verdict (LICM's is_pure_invariant) or, for
# LICM, a MEM-PURE + NOTHROW call in a wholly memory-write-free loop.  -OoMODREF
# now admits a resolved DIRECT call whose summary proves it WRITES NO memory
# (modref_writes = mr_none), is NON-TRAPPING, and READS only an EXACT set of
# static variables (never through a by-ref parameter), provided the RELEVANT
# REGION -- the loop body (LICM) / the intervening if-condition (SINK) -- writes
# NONE of those statics (item (d) per-static footprint, modref_call_may_access_
# static).  This reaches routines -OoPURE cannot prove mem-pure (here rd/trd take
# the address of a local) and, for LICM, fires across a loop that writes an
# UNRELATED static.
#
# This script proves, for both passes:
#   * the relaxed call is relocated ONLY with -OoMODREF, not with -O4 alone;
#   * a call reading a static the region WRITES stays put (per-static precision);
#   * a MAY-TRAP call is never speculated (LICM);
#   * runtime output is byte-identical with the lift on vs off (fixtures below).
#
# Usage: unleashed/tests/licm_modref_check.sh [path-to-ppcx64]
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

rc=0
run() { ( ulimit -v 3000000; timeout 60 "$@" ); }

licm_fx="$root/unleashed/tests/testfiles/optlicm/licm_modref_01.pp"
sink_fx="$root/unleashed/tests/testfiles/optsink/sink_modref_01.pp"

# ------------------------------------------------------------------ LICM ------
# With -OoMODREF exactly ONE call is hoisted: sum_disjoint's rd (loop writes gA,
# rd reads gB).  sum_conflict (loop writes gB) and sum_trap (may-trap call) stay.
licm_mod="$( "$CC" -Fu"$RTL" -O4 -OoMODREF -OoREPORT "$licm_fx" -FE"$tmp" 2>&1 || true )"
n_licm=$(grep -cE 'licm: hoisted a proven -OoMODREF write-free' <<<"$licm_mod" || true)
# Without -OoMODREF: no such hoist (rd is not mem-pure, so the nothrow path also
# declines, and modref_call_hoistable is gated off).
licm_off="$( "$CC" -Fu"$RTL" -O4 -OoREPORT "$licm_fx" -FE"$tmp" 2>&1 || true )"
n_licm_off=$(grep -cE 'licm: hoisted a proven -OoMODREF write-free' <<<"$licm_off" || true)

echo "LICM: -OoMODREF hoists                 = $n_licm (expect 1: sum_disjoint only)"
echo "LICM: -O4-only hoists                  = $n_licm_off (expect 0)"
[ "$n_licm" = "1" ]     || { echo "FAIL: expected exactly one -OoMODREF LICM hoist (conflict/trap kernels must decline)"; rc=1; }
[ "$n_licm_off" = "0" ] || { echo "FAIL: a modref-only LICM hoist fired without -OoMODREF"; rc=1; }

# ------------------------------------------------------------------ SINK ------
# With -OoMODREF exactly ONE call is sunk: usesink (condition b>0 writes nothing).
# nosink (condition calls bumpB, which writes gB) declines.
sink_mod="$( "$CC" -Fu"$RTL" -O4 -OoMODREF -OoREPORT "$sink_fx" -FE"$tmp" 2>&1 || true )"
n_sink=$(grep -cE 'sink: pure assignment sunk' <<<"$sink_mod" || true)
sink_off="$( "$CC" -Fu"$RTL" -O4 -OoREPORT "$sink_fx" -FE"$tmp" 2>&1 || true )"
n_sink_off=$(grep -cE 'sink: pure assignment sunk' <<<"$sink_off" || true)

echo "SINK: -OoMODREF sinks                  = $n_sink (expect 1: usesink only)"
echo "SINK: -O4-only sinks                   = $n_sink_off (expect 0)"
[ "$n_sink" = "1" ]     || { echo "FAIL: expected exactly one -OoMODREF call sink (nosink must decline)"; rc=1; }
[ "$n_sink_off" = "0" ] || { echo "FAIL: a modref-only call sink fired without -OoMODREF"; rc=1; }

# ------------------------------------------------------- runtime bit-exact ----
for pair in "licm_modref_01:$licm_fx" "sink_modref_01:$sink_fx"; do
  name="${pair%%:*}"; src="${pair#*:}"
  off=""; on=""
  if "$CC" -Fu"$RTL" -O4 "$src" -FE"$tmp" >/dev/null 2>&1; then off="$(run "$tmp/$name" 2>&1; echo "rc=$?")"; else echo "FAIL: $name did not compile (-O4)"; rc=1; fi
  if "$CC" -Fu"$RTL" -O4 -OoMODREF "$src" -FE"$tmp" >/dev/null 2>&1; then on="$(run "$tmp/$name" 2>&1; echo "rc=$?")"; else echo "FAIL: $name did not compile (-OoMODREF)"; rc=1; fi
  if [ "$off" = "$on" ] && [ "$on" = "ok"$'\n'"rc=0" ]; then
    echo "runtime $name: OK (identical on/off: $on)"
  else
    echo "FAIL: $name runtime differs or non-ok (off=[$off] on=[$on])"; rc=1
  fi
done

[ "$rc" -eq 0 ] && echo "PASS: -OoMODREF relocates write-free non-trapping region-stable calls in -OoLICM/-OoSINK, per-static gated and bit-exact"
exit "$rc"
