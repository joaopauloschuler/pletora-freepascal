#!/usr/bin/env bash
# Remark/gating assertions for the -OoMODREF lift of GVN-PRE's "any call"
# memory invalidation (compiler/optloop.pas).
#
# GVN-PRE value-numbers side-effect-free scalar expressions and reuses a value
# already available on every path.  A value-numbered MEMORY read (gvn_mem: a
# deref / global / addr-taken load) used to be invalidated by ANY call, in both
# the straight-line barrier (gvn_has_sideeffects) and the loop kill collector
# (gvn_kill_cb).  Under -OoMODREF a resolved DIRECT call whose mod/ref summary
# proves it writes NO memory (modref_writes = mr_none) -- even an impure call
# that may READ globals, do input or trap -- can no longer clobber a memory
# reader, so the read stays available across it.  writes = mr_byref (a by-ref
# write to caller storage) is NOT admitted (it could alias the read), nor is an
# indirect / global-writing call.
#
# The reuse emits an -OoREPORT remark naming the mod/ref write-free call.  This
# script proves it fires only with -OoMODREF, in both the straight-line and the
# loop-carried shape, and stays conservative for a global-writing, a by-ref
# writing and an indirect call.  Runtime correctness is proven by the fixture
# testfiles/optgvnpre/optgvnpre_modref_01.pp.
#
# Usage: unleashed/tests/gvnpre_modref_check.sh [path-to-ppcx64]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ---- A: reuse across a write-free impure call (straight-line + loop) --------
cat > "$tmp/a.pp" <<'EOF'
program a;
{$mode objfpc}
var garr: array[0..15] of longint;
{ impure: reads a global + a possibly-trapping div, but writes NO memory }
function rd(x: longint): longint; noinline;
begin rd := garr[x and 15] + (100 div ((x and 7) + 1)); end;
{ straight-line: p^ read, write-free call, p^ read again }
function straight(p: plongint; x: longint): longint; noinline;
var a, b, j: longint;
begin a := p^ * 7 + 2; j := rd(x); b := p^ * 7 + 2; straight := a + b + j; end;
{ loop-carried: p^ available on entry, reused across the back-edge }
function looped(p: plongint; n: longint): longint; noinline;
var i, acc, j, t: longint;
begin
  acc := 0; j := 0; i := 1; t := p^ * 7 + 2;
  while i <= n do begin j := j + rd(i); acc := acc + (p^ * 7 + 2) + t; i := i + 1; end;
  looped := acc + j;
end;
begin garr[0] := 1; writeln(straight(@garr[0], 3) + looped(@garr[0], 3)); end.
EOF

# ---- B: calls that must STAY barriers (no reuse across them) ----------------
cat > "$tmp/b.pp" <<'EOF'
program b;
{$mode objfpc}
type tproc = procedure(x: longint);
var g: longint; pv: tproc;
procedure wglob(x: longint); noinline; begin g := g + x; end;      { writes a global }
procedure mfill(out y: longint); noinline; begin y := 7; end;      { writes a by-ref out param }
procedure dummy(x: longint); noinline; begin g := x; end;
function across_global(p: plongint; x: longint): longint; noinline;
var a, b: longint; begin a := p^ * 7 + 2; wglob(x); b := p^ * 7 + 2; across_global := a + b; end;
function across_byref(p: plongint): longint; noinline;
var a, b, t: longint; begin a := p^ * 7 + 2; mfill(t); b := p^ * 7 + 2; across_byref := a + b + t; end;
function across_indirect(p: plongint; x: longint): longint; noinline;
var a, b: longint; begin a := p^ * 7 + 2; pv(x); b := p^ * 7 + 2; across_indirect := a + b; end;
begin pv := @dummy; g := 0;
  writeln(across_global(@g, 1) + across_byref(@g) + across_indirect(@g, 2)); end.
EOF

remark='gvnpre: eliminated .* across a mod/ref write-free call'

a_on=$(  "$CC" -Fu"$RTL" -O4 -OoMODREF -OoGVNPRE -OoREPORT "$tmp/a.pp" -FE"$tmp" 2>&1 | grep -cE "$remark" || true )
a_off=$( "$CC" -Fu"$RTL" -O4 -OoGVNPRE -OoREPORT "$tmp/a.pp" -FE"$tmp" 2>&1 | grep -cE 'gvnpre:' || true )
b_on=$(  "$CC" -Fu"$RTL" -O4 -OoMODREF -OoGVNPRE -OoREPORT "$tmp/b.pp" -FE"$tmp" 2>&1 | grep -cE 'gvnpre:' || true )

echo "A with -OoMODREF: write-free-call reuse remarks = $a_on (expect 2: straight + loop)"
echo "A without -OoMODREF: any gvnpre remarks         = $a_off (expect 0)"
echo "B with -OoMODREF: any gvnpre remarks            = $b_on (expect 0: global/byref/indirect calls stay barriers)"

rc=0
[ "$a_on" -ge 2 ] || { echo "FAIL: GVN-PRE did not reuse a memory read across a write-free call under -OoMODREF (straight-line and loop)"; rc=1; }
[ "$a_off" = "0" ] || { echo "FAIL: GVN-PRE reused a memory read across a call WITHOUT -OoMODREF"; rc=1; }
[ "$b_on" = "0" ]  || { echo "FAIL: GVN-PRE wrongly reused a memory read across a global-writing / by-ref-writing / indirect call"; rc=1; }

[ "$rc" -eq 0 ] && echo "PASS: -OoMODREF relaxes GVN-PRE's any-call memory invalidation soundly, correctly gated"
exit "$rc"
