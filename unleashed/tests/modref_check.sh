#!/usr/bin/env bash
# Codegen assertions for the -OoMODREF interprocedural mod/ref consumer.
#
# -OoMODREF records, per routine, a conservative memory-access summary (what it
# READS / WRITES, each: nothing / only through its own by-ref parameters /
# unknown-global, plus a can-trap bit) and refines -OoPURE's binary verdict so a
# call that provably neither reads nor writes the location in question is no
# longer a barrier even though the callee is impure.  Two consumers are relaxed:
#
#   1. the extended field/element dead-store elimination (optdeadstore.pas):
#      a pending store survives a call whose summary does not touch it.
#   2. loop store-motion (optloop.pas): a global promoted to a register across a
#      loop survives a body call that provably touches no global memory and
#      cannot trap.
#
# Assertions (assembly inspected with -al -s; mnemonics can't be matched by the
# %CHECKBIN_* directives):
#   * a dead local field store is ELIMINATED across a helper that writes only its
#     own out parameter (bound to a caller local) -- and KEPT without -OoMODREF;
#   * a dead static-array store is KEPT across a global-writing call;
#   * a dead local store is KEPT across an INDIRECT (procvar) call;
#   * a global written every iteration is PROMOTED to a register across a loop
#     whose body calls that same locals-only helper -- and NOT promoted without.
# The runtime fixture testfiles/modref/modref_bitexact_01.pp proves results stay
# correct.
#
# Usage: unleashed/tests/modref_check.sh [path-to-ppcx64]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/k.pp" <<'EOF'
program k;
{$mode objfpc}
type TArr = array[0..3] of longint;
     TProc = procedure(x: longint);
var g: longint; sg: TArr; pv: TProc;
{ impure but writes ONLY its own out parameter -> disjoint from any caller
  local / global not passed to it }
procedure mfill(out y: longint); noinline;
begin y := 7; end;
{ impure: writes a global static -> unknown-global write }
procedure mwglob(x: longint); noinline;
begin g := g + x; end;
procedure dummy(x: longint); noinline;
begin g := x; end;
{ dead local field store across a disjoint (out-param-writer) call -> removed }
function kdisjoint(v: longint): longint; noinline;
var a: TArr; t: longint;
begin a[0]:=111; a[1]:=11; a[2]:=12; a[3]:=13; mfill(t); a[0]:=222;
  kdisjoint:=a[0]+a[1]+a[2]+a[3]+t; end;
{ dead static-array store across a global-writing call -> kept }
function kglobal(v: longint): longint; noinline;
begin sg[0]:=333; sg[1]:=21; sg[2]:=22; sg[3]:=23; mwglob(v); sg[0]:=444;
  kglobal:=sg[0]+sg[1]+sg[2]+sg[3]; end;
{ dead local store across an INDIRECT call -> kept }
function kindirect(v: longint): longint; noinline;
var a: TArr;
begin a[0]:=555; a[1]:=31; a[2]:=32; a[3]:=33; pv(v); a[0]:=666;
  kindirect:=a[0]+a[1]+a[2]+a[3]; end;
begin pv:=@dummy; writeln(kdisjoint(2)+kglobal(3)+kindirect(4)); end.
EOF

# store-motion kernel: a global written every iteration, loop body calling the
# locals-only helper
cat > "$tmp/sm.pp" <<'EOF'
program smt;
{$mode objfpc}
var g: longint;
procedure sink(out y: longint); noinline;
begin y := 0; end;
function sm(n: longint): longint; noinline;
var i, tmp: longint;
begin
  for i:=1 to n do begin g := g + i; sink(tmp); end;
  sm := g + tmp;
end;
begin g:=0; writeln(sm(5)); end.
EOF

count_store() { grep -cE "movl[[:space:]]+\\\$$1," "$2" || true; }

# ---- DSE: with -OoMODREF -----------------------------------------------------
"$CC" -Fu"$RTL" -O3 -OoMODREF -Oodeadstore -al -s "$tmp/k.pp" -FE"$tmp" >/dev/null 2>&1
m111=$(count_store 111 "$tmp/k.s")   # disjoint out-param writer -> removed (0)
m333=$(count_store 333 "$tmp/k.s")   # static base, global writer -> kept  (1)
m555=$(count_store 555 "$tmp/k.s")   # local base, indirect call  -> kept  (1)

# ---- DSE: baseline without -OoMODREF (every impure call is a barrier) --------
"$CC" -Fu"$RTL" -O3 -Oodeadstore -al -s "$tmp/k.pp" -FE"$tmp" >/dev/null 2>&1
b111=$(count_store 111 "$tmp/k.s")   # kept (1)

# ---- store motion: promotion remark present only with -OoMODREF --------------
sm_mod="$("$CC" -Fu"$RTL" -O3 -OoMODREF -OoSTOREMOTION -OoREPORT "$tmp/sm.pp" -o"$tmp/sm" 2>&1 | grep -c 'storemotion: promoted' || true)"
sm_base="$("$CC" -Fu"$RTL" -O3 -OoSTOREMOTION -OoREPORT "$tmp/sm.pp" -o"$tmp/sm" 2>&1 | grep -c 'storemotion: promoted' || true)"

echo "DSE with -OoMODREF: disjoint out-param writer 111 count=$m111 (expect 0, removed)"
echo "DSE with -OoMODREF: static base, global writer 333 count=$m333 (expect 1, kept)"
echo "DSE with -OoMODREF: local base, indirect call  555 count=$m555 (expect 1, kept)"
echo "DSE baseline (no -OoMODREF):                    111 count=$b111 (expect 1, kept)"
echo "store motion promotions with -OoMODREF=$sm_mod (expect >=1), baseline=$sm_base (expect 0)"

rc=0
[ "$m111" = "0" ] || { echo "FAIL: dead store not removed across a disjoint (out-param writer) call"; rc=1; }
[ "$m333" = "1" ] || { echo "FAIL: dead static-array store wrongly removed across a global-writing call"; rc=1; }
[ "$m555" = "1" ] || { echo "FAIL: dead store wrongly removed across an indirect call"; rc=1; }
[ "$b111" = "1" ] || { echo "FAIL: baseline (no -OoMODREF) wrongly removed a store across a call"; rc=1; }
[ "$sm_mod" -ge 1 ] || { echo "FAIL: store motion did not promote across a locals-only call under -OoMODREF"; rc=1; }
[ "$sm_base" = "0" ] || { echo "FAIL: store motion promoted across a call without -OoMODREF"; rc=1; }

[ "$rc" -eq 0 ] && echo "PASS: -OoMODREF relaxes the DSE and store-motion call barriers soundly"
exit "$rc"
