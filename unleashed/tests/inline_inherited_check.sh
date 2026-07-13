#!/usr/bin/env bash
# Codegen + runtime checks for inlining CLASS methods whose body contains an
# `inherited` call (checknodeinlining refusal (b), pi_has_inherited).
#
# For a class method self is a plain instance pointer passed as an ordinary
# hidden value parameter, so the node inliner (ncal.replaceparaload) rebinds the
# inherited call's self load to the call site's self actual exactly like any
# other parameter, and the inherited target is statically (non-virtually)
# dispatched.  Such bodies now splice into a SAME-UNIT caller.  This script
# LOCKS THAT IN: the class inline method must actually inline at -O3 (NO `call`
# to its mangled name in the caller), the inherited callee must remain a direct
# call, and the result must be correct including a self field read through the
# rebound self (both for a static and for a virtual ancestor method).
#
# Old-style `object` methods (value self, by reference) still miscompile the
# spliced inherited self, and a cross-unit body's ppu-reconstructed self does
# not line up with the caller's paras -- both keep the refusal.  Parts C and D
# prove those shapes STAY out of line and still run correctly.
#
# Usage: unleashed/tests/inline_inherited_check.sh [path-to-ppcx64]
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

rc=0
fail() { echo "FAIL: $*"; rc=1; }

run() { ( ulimit -v 3000000; timeout 60 "$@" ); }

# a `call` to the mangled infix of the inline method means NOT inlined
calls() { grep -Eq "call[[:space:]].*_\\\$\\\$_$1" "$2"; }

# ---------------------------------------------------------------------------
# Part A: class method calling inherited (static + virtual ancestor) inlines
#         same-unit at -O3; self field read through the rebound self.
# ---------------------------------------------------------------------------
cat > "$tmp/a.pp" <<'EOF'
{$mode objfpc}
program a;
type
  TBase = class
    F: longint;
    function Base(x: longint): longint;
    function VBase(x: longint): longint; virtual;
  end;
  TDer = class(TBase)
    function Calc(x: longint): longint; inline;
    function VCalc(x: longint): longint; inline;
  end;
function TBase.Base(x: longint): longint;
begin Result := x*2 + F; end;
function TBase.VBase(x: longint): longint;
begin Result := x*3 + F; end;
function TDer.Calc(x: longint): longint;
begin Result := inherited Base(x) + 1; end;             { static ancestor }
function TDer.VCalc(x: longint): longint;
begin Result := inherited VBase(x) + 5; end;            { virtual ancestor, static dispatch }
var d: TDer;
begin
  d := TDer.Create;
  d.F := 100;
  writeln(d.Calc(10));    { 10*2 +100 +1 = 121 }
  writeln(d.VCalc(10));   { 10*3 +100 +5 = 135 }
  d.F := 200;             { prove self is re-read, not cached }
  writeln(d.Calc(3));     { 3*2 +200 +1 = 207 }
  d.Free;
end.
EOF
if run "$CC" -Fu"$RTL" -O3 -al -FE"$tmp" "$tmp/a.pp" >/dev/null 2>&1; then
  calls CALC "$tmp/a.s"  && fail "Part A: TDer.Calc NOT inlined at -O3 (call present)"
  calls VCALC "$tmp/a.s" && fail "Part A: TDer.VCalc NOT inlined at -O3 (call present)"
  # the inherited targets must still be direct calls in the caller
  grep -Eq 'call[[:space:]].*_\$\$_BASE'  "$tmp/a.s" || fail "Part A: inherited Base not called directly"
  grep -Eq 'call[[:space:]].*_\$\$_VBASE' "$tmp/a.s" || fail "Part A: inherited VBase not called directly"
  out="$(run "$tmp/a" 2>&1)"
  [ "$out" = $'121\n135\n207' ] || fail "Part A: wrong output [$out] (expected 121 / 135 / 207)"
else
  fail "Part A: compile failed"
fi

# ---------------------------------------------------------------------------
# Part B: inline inherited method invoked from INSIDE another method -- the
#         inherited self must bind to the call's receiver, not the caller's self.
# ---------------------------------------------------------------------------
cat > "$tmp/b.pp" <<'EOF'
{$mode objfpc}
program b;
type
  TBase = class
    F: longint;
    procedure Add(x: longint);
  end;
  TDer = class(TBase)
    procedure Bump(x: longint); inline;
  end;
  TUser = class
    UF: longint;
    function Use(d: TDer; x: longint): longint;
  end;
procedure TBase.Add(x: longint);
begin F := F + x; end;
procedure TDer.Bump(x: longint);
begin inherited Add(x * 2); end;                        { inherited procedure with args }
function TUser.Use(d: TDer; x: longint): longint;
begin
  UF := 7;
  d.Bump(x);            { inlined here: self must be d, not Self(TUser) }
  Result := d.F + UF;
end;
var u: TUser; d: TDer;
begin
  d := TDer.Create; d.F := 10;
  u := TUser.Create;
  writeln(u.Use(d, 4));   { d.F := 10 + 4*2 = 18; +UF 7 = 25 }
  writeln(u.Use(d, 1));   { d.F := 18 + 1*2 = 20; +7 = 27 }
  d.Free; u.Free;
end.
EOF
if run "$CC" -Fu"$RTL" -O3 -al -FE"$tmp" "$tmp/b.pp" >/dev/null 2>&1; then
  calls BUMP "$tmp/b.s" && fail "Part B: TDer.Bump NOT inlined at -O3 (call present)"
  out="$(run "$tmp/b" 2>&1)"
  [ "$out" = $'25\n27' ] || fail "Part B: wrong output [$out] (expected 25 / 27)"
else
  fail "Part B: compile failed"
fi

# ---------------------------------------------------------------------------
# Part C: old-style object method with inherited STAYS refused, runs correct.
# ---------------------------------------------------------------------------
cat > "$tmp/c.pp" <<'EOF'
{$mode objfpc}
program c;
type
  TObj = object
    G: longint;
    function OB(x: longint): longint;
  end;
  TObjD = object(TObj)
    function OCalc(x: longint): longint; inline;
  end;
function TObj.OB(x: longint): longint;
begin Result := x + G; end;
function TObjD.OCalc(x: longint): longint;
begin Result := inherited OB(x) * 2; end;
var od: TObjD;
begin
  od.G := 5;
  writeln(od.OCalc(3));   { (3+5)*2 = 16 }
end.
EOF
noteC="$(run "$CC" -Fu"$RTL" -vn -O3 -FE"$tmp" "$tmp/c.pp" 2>&1)"
echo "$noteC" | grep -Eq 'OCalc.*not inlined \(inherited\)' || fail "Part C: object inherited note missing"
out="$(run "$tmp/c" 2>&1)"
[ "$out" = "16" ] || fail "Part C: wrong output [$out] (expected 16)"

# ---------------------------------------------------------------------------
# Part D: cross-unit class inherited STAYS out of line, runs correct.
# ---------------------------------------------------------------------------
cat > "$tmp/bunit.pas" <<'EOF'
unit bunit;
{$mode objfpc}
interface
type
  TBase = class
    F: longint;
    function Base(x: longint): longint;
  end;
  TDer = class(TBase)
    function Calc(x: longint): longint; inline;
  end;
implementation
function TBase.Base(x: longint): longint;
begin Result := x*2 + F; end;
function TDer.Calc(x: longint): longint;
begin Result := inherited Base(x) + 1; end;
end.
EOF
cat > "$tmp/dmain.pp" <<'EOF'
{$mode objfpc}
program dmain;
uses bunit;
var d: TDer;
begin
  d := TDer.Create; d.F := 100;
  writeln(d.Calc(10));   { 121 }
  d.Free;
end.
EOF
if run "$CC" -Fu"$RTL" -O3 -al -FE"$tmp" -FU"$tmp" "$tmp/dmain.pp" >/dev/null 2>&1; then
  # in dmain the cross-unit Calc must remain a call (not spliced)
  grep -Eq 'call[[:space:]].*_\$\$_CALC' "$tmp/dmain.s" || fail "Part D: cross-unit Calc unexpectedly inlined"
  out="$(run "$tmp/dmain" 2>&1)"
  [ "$out" = "121" ] || fail "Part D: wrong output [$out] (expected 121)"
else
  fail "Part D: cross-unit compile failed"
fi

if [ "$rc" -eq 0 ]; then
  echo "PASS: class-method inherited inlines same-unit at -O3 (no call, self rebound, static+virtual ancestor correct); object and cross-unit inherited stay out of line and run correctly"
fi
exit "$rc"
