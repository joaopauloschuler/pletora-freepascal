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
# The relaxation is restricted to calls whose actuals are all simple-typed,
# because reassoc's addend duplicator cannot re-typecheck a copy that passes a
# fixed array to an open-array parameter.  This script proves:
#   * the write-free addend is split only with -OoMODREF (modref remark), and NOT
#     under -OoPURE alone;
#   * an open-array-parameter call is NOT admitted, and the file still COMPILES
#     cleanly (no reassoc duplication error);
#   * a global-writing call stays declined.
# Runtime correctness is proven by testfiles/optreassoc/reassoc_modref_01.pp.
#
# Usage: unleashed/tests/reassoc_modref_check.sh [path-to-ppcx64]
set -euo pipefail

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

# --- with -OoMODREF: writefree splits (modref remark), file compiles clean -----
mod_out="$( "$CC" -Fu"$RTL" -O4 -OoMODREF -OoREASSOC -OoREPORT "$tmp/r.pp" -FE"$tmp" 2>&1 || true )"
n_modref=$(grep -cE 'reassoc: reduction .* via -OoMODREF' <<<"$mod_out" || true)
n_error=$(grep -cE 'Error:' <<<"$mod_out" || true)

# --- without -OoMODREF (pure only): writefree must NOT split -------------------
pure_out="$( "$CC" -Fu"$RTL" -O4 -OoPURE -OoREASSOC -OoREPORT "$tmp/r.pp" -FE"$tmp" 2>&1 || true )"
n_pure_split=$(grep -cE 'reassoc: reduction .* via -OoMODREF' <<<"$pure_out" || true)

echo "with -OoMODREF: write-free split remarks = $n_modref (expect 1: viaaddr)"
echo "with -OoMODREF: compile errors           = $n_error (expect 0: open-array call NOT admitted)"
echo "with -OoPURE only: modref split remarks   = $n_pure_split (expect 0)"

[ "$n_modref" = "1" ] || { echo "FAIL: -OoMODREF did not split the write-free reduction addend"; rc=1; }
[ "$n_error" = "0" ]  || { echo "FAIL: an open-array-parameter call was admitted and broke reassoc duplication"; rc=1; }
[ "$n_pure_split" = "0" ] || { echo "FAIL: a modref-only split fired without -OoMODREF"; rc=1; }

[ "$rc" -eq 0 ] && echo "PASS: -OoMODREF widens the -OoREASSOC addend fence to write-free non-trapping calls, soundly and correctly gated"
exit "$rc"
