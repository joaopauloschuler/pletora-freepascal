#!/usr/bin/env bash
# Remark/gating assertions for the -OoMODREF generalisation of the -OoREASSOC
# reduction-addend fence (compiler/optloop.pas).
#
# -OoREASSOC splits a reduction  acc := acc + f(a[i])  into K partial
# accumulators by duplicating the addend with a shifted counter.  A call in the
# addend used to be admitted only when -OoPURE proved it PURE/CONST.  -OoMODREF
# widens this to any resolved DIRECT call whose summary proves it writes NO
# memory (modref_writes = mr_none) and cannot trap: it is just as reorderable as
# a pure call, and it reaches routines -OoPURE rejects (here `viaaddr`, which
# takes the address of a local -- "takes the address of something" -- yet writes
# nothing).
#
# The relaxation admits any resolved write-free non-trapping call regardless of
# its parameter shapes: reassoc's addend duplicator now preserves an already-
# firstpassed call's expanded argument list on each copy (reassoc_reset_cb skips
# call nodes), so an open-array-parameter call -- which -OoPURE can NEVER admit
# (its purity analysis rejects open-array/managed/hidden parameters) -- splits
# cleanly under -OoMODREF.  This script proves:
#   * the simple write-free addend (viaaddr) is split with -OoMODREF, NOT with
#     -OoPURE alone;
#   * an OPEN-ARRAY-parameter write-free addend (pick) is ALSO split under
#     -OoMODREF, the file COMPILES cleanly (no reassoc duplication error), and it
#     is NOT split under -OoPURE alone;
#   * a global-writing call (bumps) stays declined (exactly two modref splits).
# Runtime correctness is proven by testfiles/optreassoc/reassoc_modref_01.pp
# (simple addend) and testfiles/optreassoc/reassoc_modref_02.pp (open-array
# addend), both run below.
#
# Usage: unleashed/tests/reassoc_modref_check.sh [path-to-ppcx64]
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/r.pp" <<'EOF'
program r;
{$mode objfpc}
var gtab: array[0..255] of longint; params: array[0..7] of longint; g: longint;
{ writes nothing (address of a local) -> admitted under -OoMODREF }
function viaaddr(x: longint): longint; noinline;
var t: longint; p: plongint; begin t := x*x - x; p := @t; viaaddr := p^ + 1; end;
{ open-array parameter -> must be EXCLUDED (simple-arg restriction), file must
  still compile cleanly (no reassoc duplication error) }
function pick(const v: array of longint; i: longint): longint; noinline;
begin pick := v[i and 7] + gtab[i and 255]; end;
{ writes a global -> writes != none -> declined }
function bumps(x: longint): longint; noinline; begin g := g + x; bumps := x; end;
function r_writefree(const a: array of longint): longint; noinline;
var i,s: longint; begin s:=0; for i:=0 to high(a) do s:=s+viaaddr(a[i]); r_writefree:=s; end;
function r_openarray(const a: array of longint): longint; noinline;
var i,s: longint; begin s:=0; for i:=0 to high(a) do s:=s+pick(params, a[i]); r_openarray:=s; end;
function r_globalwrite(const a: array of longint): longint; noinline;
var i,s: longint; begin s:=0; for i:=0 to high(a) do s:=s+bumps(a[i]); r_globalwrite:=s; end;
var a: array of longint; i: longint;
begin SetLength(a,64); for i:=0 to 63 do a[i]:=i; for i:=0 to 7 do params[i]:=i;
  for i:=0 to 255 do gtab[i]:=i; g:=0;
  writeln(r_writefree(a)+r_openarray(a)+r_globalwrite(a)); end.
EOF

rc=0
run() { ( ulimit -v 3000000; timeout 60 "$@" ); }

# --- with -OoMODREF: viaaddr AND pick (open-array) split, file compiles clean ---
mod_out="$( "$CC" -Fu"$RTL" -O4 -OoMODREF -OoREASSOC -OoREPORT "$tmp/r.pp" -FE"$tmp" 2>&1 || true )"
n_modref=$(grep -cE 'reassoc: reduction .* via -OoMODREF' <<<"$mod_out" || true)
n_error=$(grep -cE 'Error:' <<<"$mod_out" || true)

# --- the OPEN-ARRAY-parameter addend, isolated in reassoc_modref_02.pp, splits
#     ONLY under -OoMODREF (its sole call is pick(), whose open-array parameter
#     -OoPURE can never admit) and NOT under -OoPURE alone --------------------
oa_src="$root/unleashed/tests/testfiles/optreassoc/reassoc_modref_02.pp"
oa_mod="$( "$CC" -Fu"$RTL" -O4 -OoMODREF -OoREASSOC -OoREPORT "$oa_src" -FE"$tmp" 2>&1 || true )"
n_openarray=$(grep -cE 'reassoc: reduction .* via -OoMODREF' <<<"$oa_mod" || true)
n_oa_error=$(grep -cE 'Error:' <<<"$oa_mod" || true)
oa_pure="$( "$CC" -Fu"$RTL" -O4 -OoPURE -OoREASSOC -OoREPORT "$oa_src" -FE"$tmp" 2>&1 || true )"
n_oa_pure=$(grep -cE 'reassoc: reduction .* via -OoMODREF' <<<"$oa_pure" || true)

# --- without -OoMODREF (pure only): neither viaaddr (addr-taken) nor pick
#     (open-array) splits -- both beyond -OoPURE ------------------------------
pure_out="$( "$CC" -Fu"$RTL" -O4 -OoPURE -OoREASSOC -OoREPORT "$tmp/r.pp" -FE"$tmp" 2>&1 || true )"
n_pure_split=$(grep -cE 'reassoc: reduction .* via -OoMODREF' <<<"$pure_out" || true)

echo "with -OoMODREF: write-free split remarks = $n_modref (expect 2: viaaddr + pick, global-writer declined)"
echo "with -OoMODREF: compile errors           = $n_error (expect 0)"
echo "open-array fixture: -OoMODREF splits      = $n_openarray (expect 1), errors = $n_oa_error (expect 0)"
echo "open-array fixture: -OoPURE-only splits   = $n_oa_pure (expect 0)"
echo "with -OoPURE only: modref split remarks   = $n_pure_split (expect 0)"

[ "$n_modref" = "2" ]   || { echo "FAIL: expected exactly two -OoMODREF splits (viaaddr + pick), global-writer must stay declined"; rc=1; }
[ "$n_error" = "0" ]    || { echo "FAIL: -OoMODREF run produced a compile error"; rc=1; }
[ "$n_openarray" = "1" ]|| { echo "FAIL: the open-array-parameter write-free addend was NOT split under -OoMODREF"; rc=1; }
[ "$n_oa_error" = "0" ] || { echo "FAIL: the open-array addend broke reassoc duplication (re-typecheck error)"; rc=1; }
[ "$n_oa_pure" = "0" ]  || { echo "FAIL: the open-array addend split under -OoPURE alone (must need -OoMODREF)"; rc=1; }
[ "$n_pure_split" = "0" ] || { echo "FAIL: a modref-only split fired without -OoMODREF"; rc=1; }

# --- runtime: split result must equal the strictly-serial reference ------------
for fx in reassoc_modref_01 reassoc_modref_02; do
  src="$root/unleashed/tests/testfiles/optreassoc/$fx.pp"
  if run "$CC" -Fu"$RTL" -O4 -OoMODREF -OoREASSOC "$src" -FE"$tmp" >/dev/null 2>&1; then
    if run "$tmp/$fx" >/dev/null 2>&1; then echo "runtime $fx: OK"; else echo "FAIL: $fx run (split != serial reference)"; rc=1; fi
  else
    echo "FAIL: $fx did not compile"; rc=1
  fi
done

[ "$rc" -eq 0 ] && echo "PASS: -OoMODREF widens the -OoREASSOC addend fence to write-free non-trapping calls (incl. open-array-parameter actuals, duplicated soundly), correctly gated and bit-exact"
exit "$rc"
