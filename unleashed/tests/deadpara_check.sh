#!/usr/bin/env bash
# Codegen assertions for -OoDEADPARA (interprocedural dead-parameter elimination,
# part (a) of the gcc -fipa-sra port).
#
# -OoDEADPARA records, per routine, a per-formal REFERENCE bitmap (bit N set =
# paras[N] is loaded in the body) and serializes it cross-unit through the shared
# per-procdef PPU optimizer-summary blob (the optsum_deadpara tag).  A CLEAR bit
# for an in-range by-value scalar formal means the callee provably never reads
# it, so a later-compiled CALLER at a resolved DIRECT call site stops EVALUATING a
# side-effect-free, non-trapping actual bound to it and passes a cheap constant
# instead (Design 2: caller-side argument-evaluation elision, signature
# preserving).
#
# Assertions (assembly inspected with -al -s; the expensive dead actual is a pure
# imul-heavy expression, so the count of `imul` in the emitted code is the
# observable signal):
#   * an expensive PURE dead actual is ELIDED (imul disappears) only with
#     -OoDEADPARA, and KEPT without it;
#   * a parameter that IS read keeps its actual's evaluation;
#   * a SIDE-EFFECTING actual (a function call) is KEPT even though the parameter
#     is dead (only provably side-effect-free actuals are elided);
#   * a VIRTUAL-method callee is never rewritten;
#   * an INDIRECT (procvar) call is never rewritten;
#   * an EXPORTED callee is never rewritten;
#   * the cross-unit case works iff the callee unit was compiled with -OoDEADPARA
#     (its summary serialized to the ppu).
# The runtime fixture testfiles/deadpara/deadpara_bitexact_01.pp proves results
# (and the evaluation count of a side-effecting actual) stay correct.
#
# Usage: unleashed/tests/deadpara_check.sh [path-to-ppcx64]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

imul_count() { grep -cE '[[:space:]]imul' "$1" || true; }

rc=0

# ---- 1/2: expensive pure dead actual elided; read-param actual kept ----------
cat > "$tmp/a.pp" <<'EOF'
program a;
{$mode objfpc}{$Q-}{$R-}
function ignore2(used, dead: longint): longint; noinline;
begin ignore2 := used + 1; end;
function useboth(a, b: longint): longint; noinline;
begin useboth := a + b; end;
var i, s: longint;
begin
  s := 0;
  for i := 1 to 10 do s := s + ignore2(i, i*i*i + i*i + i*7);  { dead: elidable }
  for i := 1 to 10 do s := s + useboth(i, i*i*i + i*i + i*7);  { read: kept     }
  writeln(s);
end.
EOF
# baseline includes both loops' imuls (>=6). With -OoDEADPARA the dead-actual
# loop's imuls vanish but the read-param loop's imuls remain (>=3, < baseline).
"$CC" -Fu"$RTL" -O2 -al -s "$tmp/a.pp" -FE"$tmp" >/dev/null 2>&1
a_off=$(imul_count "$tmp/a.s")
"$CC" -Fu"$RTL" -O2 -OoDEADPARA -al -s "$tmp/a.pp" -FE"$tmp" >/dev/null 2>&1
a_on=$(imul_count "$tmp/a.s")
echo "pure dead actual: imul off=$a_off on=$a_on (on must be strictly fewer, and >0 for the kept read-param loop)"
[ "$a_on" -lt "$a_off" ] || { echo "FAIL: expensive dead actual not elided under -OoDEADPARA"; rc=1; }
[ "$a_on" -gt 0 ]        || { echo "FAIL: a read parameter's actual was wrongly elided"; rc=1; }

# ---- 3: side-effecting dead actual kept --------------------------------------
cat > "$tmp/s.pp" <<'EOF'
program s;
{$mode objfpc}
var g: longint;
function sidefx(x: longint): longint; noinline;
begin inc(g); sidefx := x; end;
function ignore2(used, dead: longint): longint; noinline;
begin ignore2 := used + 1; end;
var i, acc: longint;
begin g:=0; acc:=0;
  for i := 1 to 10 do acc := acc + ignore2(i, sidefx(i));
  writeln(acc, ' ', g);
end.
EOF
"$CC" -Fu"$RTL" -O2 -OoDEADPARA -al -s "$tmp/s.pp" -FE"$tmp" >/dev/null 2>&1
s_calls=$(grep -cE 'call[[:space:]].*SIDEFX' "$tmp/s.s" || true)
echo "side-effecting dead actual: call SIDEFX count=$s_calls (expect >=1, kept)"
[ "$s_calls" -ge 1 ] || { echo "FAIL: a side-effecting actual was wrongly elided"; rc=1; }

# ---- 4: virtual-method callee untouched --------------------------------------
cat > "$tmp/v.pp" <<'EOF'
program v;
{$mode objfpc}
type TBase = class
  function vm(used, dead: longint): longint; virtual;
end;
function TBase.vm(used, dead: longint): longint; begin vm := used + 1; end;
var o: TBase; i, s: longint;
begin o := TBase.Create; s := 0;
  for i := 1 to 10 do s := s + o.vm(i, i*i*i + i*i + i*7);
  writeln(s); o.Free;
end.
EOF
"$CC" -Fu"$RTL" -O2 -al -s "$tmp/v.pp" -FE"$tmp" >/dev/null 2>&1
v_off=$(imul_count "$tmp/v.s")
"$CC" -Fu"$RTL" -O2 -OoDEADPARA -al -s "$tmp/v.pp" -FE"$tmp" >/dev/null 2>&1
v_on=$(imul_count "$tmp/v.s")
echo "virtual callee: imul off=$v_off on=$v_on (must be equal, untouched)"
[ "$v_on" = "$v_off" ] && [ "$v_on" -gt 0 ] || { echo "FAIL: a virtual-method callee's actual was rewritten"; rc=1; }

# ---- 5: indirect (procvar) call untouched ------------------------------------
cat > "$tmp/p.pp" <<'EOF'
program p;
{$mode objfpc}
type TFn = function(used, dead: longint): longint;
function ignore2(used, dead: longint): longint; noinline;
begin ignore2 := used + 1; end;
var fn: TFn; i, s: longint;
begin fn := @ignore2; s := 0;
  for i := 1 to 10 do s := s + fn(i, i*i*i + i*i + i*7);
  writeln(s);
end.
EOF
"$CC" -Fu"$RTL" -O2 -al -s "$tmp/p.pp" -FE"$tmp" >/dev/null 2>&1
p_off=$(imul_count "$tmp/p.s")
"$CC" -Fu"$RTL" -O2 -OoDEADPARA -al -s "$tmp/p.pp" -FE"$tmp" >/dev/null 2>&1
p_on=$(imul_count "$tmp/p.s")
echo "procvar call: imul off=$p_off on=$p_on (must be equal, untouched)"
[ "$p_on" = "$p_off" ] && [ "$p_on" -gt 0 ] || { echo "FAIL: an indirect (procvar) call was rewritten"; rc=1; }

# ---- 6: externally-visible (public) callee untouched -------------------------
cat > "$tmp/e.pp" <<'EOF'
program e;
{$mode objfpc}
function expfn(used, dead: longint): longint; noinline; public name 'expfn_ext';
begin expfn := used + 1; end;
var i, s: longint;
begin s := 0;
  for i := 1 to 10 do s := s + expfn(i, i*i*i + i*i + i*7);
  writeln(s);
end.
EOF
"$CC" -Fu"$RTL" -O2 -OoDEADPARA -al -s "$tmp/e.pp" -FE"$tmp" >/dev/null 2>&1
e_on=$(imul_count "$tmp/e.s")
echo "public (externally-visible) callee: imul on=$e_on (expect >0, untouched)"
[ "$e_on" -gt 0 ] || { echo "FAIL: an externally-visible (public) callee's actual was rewritten"; rc=1; }

# ---- 7: cross-unit case (needs the serialized summary) -----------------------
mkdir -p "$tmp/xu"
cat > "$tmp/xu/uhelp.pp" <<'EOF'
unit uhelp;
{$mode objfpc}
interface
function helper(used, dead: longint): longint;
implementation
function helper(used, dead: longint): longint; noinline;
begin helper := used + 1; end;
end.
EOF
cat > "$tmp/xu/mx.pp" <<'EOF'
program mx;
{$mode objfpc}
uses uhelp;
var i, s: longint;
begin s := 0;
  for i := 1 to 10 do s := s + helper(i, i*i*i + i*i + i*7);
  writeln(s);
end.
EOF
# (a) unit compiled WITH -OoDEADPARA -> summary serialized -> main elides
"$CC" -Fu"$RTL" -O2 -OoDEADPARA -s "$tmp/xu/uhelp.pp" -FE"$tmp/xu" >/dev/null 2>&1
"$CC" -Fu"$RTL" -FU"$tmp/xu" -O2 -OoDEADPARA -al -s "$tmp/xu/mx.pp" -FE"$tmp/xu" >/dev/null 2>&1
xu_with=$(imul_count "$tmp/xu/mx.s")
# (b) unit compiled WITHOUT -OoDEADPARA -> no summary -> main must NOT elide
"$CC" -Fu"$RTL" -O2 -s "$tmp/xu/uhelp.pp" -FE"$tmp/xu" >/dev/null 2>&1
"$CC" -Fu"$RTL" -FU"$tmp/xu" -O2 -OoDEADPARA -al -s "$tmp/xu/mx.pp" -FE"$tmp/xu" >/dev/null 2>&1
xu_without=$(imul_count "$tmp/xu/mx.s")
echo "cross-unit: caller imul with serialized summary=$xu_with (expect 0), without=$xu_without (expect >0)"
[ "$xu_with" = "0" ]      || { echo "FAIL: cross-unit dead actual not elided from a serialized summary"; rc=1; }
[ "$xu_without" -gt 0 ]   || { echo "FAIL: cross-unit elision happened without a serialized summary (unsound)"; rc=1; }

# ---- 8: runtime fixture stays bit-exact with and without the switch ----------
FX="$root/unleashed/tests/testfiles/deadpara/deadpara_bitexact_01.pp"
"$CC" -Fu"$RTL" -O2               -o"$tmp/fx_off" -FE"$tmp" "$FX" >/dev/null 2>&1
"$CC" -Fu"$RTL" -O2 -OoDEADPARA   -o"$tmp/fx_on"  -FE"$tmp" "$FX" >/dev/null 2>&1
off_out="$( (ulimit -v 3000000; timeout 60 "$tmp/fx_off") )"
on_out="$(  (ulimit -v 3000000; timeout 60 "$tmp/fx_on")  )"
echo "fixture off: $off_out"
echo "fixture on : $on_out"
[ "$off_out" = "$on_out" ] || { echo "FAIL: -OoDEADPARA changed the fixture's observable output"; rc=1; }
echo "$on_out" | grep -q 'sidecalls=20' || { echo "FAIL: a side-effecting actual was elided (call count changed)"; rc=1; }

[ "$rc" -eq 0 ] && echo "PASS: -OoDEADPARA elides dead by-value scalar actuals soundly (direct and cross-unit)"
exit "$rc"
