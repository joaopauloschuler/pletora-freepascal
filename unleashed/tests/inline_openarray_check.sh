#!/usr/bin/env bash
# Codegen + runtime checks for inlining routines with OPEN ARRAY / ARRAY OF
# CONST value parameters (checknodeinlining refusals for "open array" and
# "array of const").
#
# An open array is 0-based inside the callee (low(a)=0) while its actual may be
# a differently-based array (e.g. array[1..N]).  A naive splice re-typechecks
# a[i] as a fixed-array index and subtracts the actual's low bound from the
# callee's 0-based i.  tcallnode.replaceparaload re-applies the call-boundary
# conversion (wraps a non-zero-based static array actual in a typeconv to the
# open-array parameter type), so the spliced accesses keep the 0-based view.
# Static arrays (any base), array constructors, slices, open strings and
# passed-through open arrays all inline correctly.
#
# A DYNAMIC array actual is itself a pointer to its data and the spliced access
# derefs the param location once more (one indirection too many); those calls
# STAY out of line (a precise note) and run correctly.
#
# Usage: unleashed/tests/inline_openarray_check.sh [path-to-ppcx64]
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
# count `call`s to the mangled infix _$$_<NAME>$ of an inline target
ncalls() { grep -Ec "call[[:space:]].*_\\\$\\\$_$1\\\$" "$2" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# Part A: non-zero-based static array actual inlines with correct re-basing.
# ---------------------------------------------------------------------------
cat > "$tmp/a.pp" <<'EOF'
{$mode objfpc}
program a;
function RSum(const x: array of longint): longint; inline;
var i: longint;
begin RSum := 0; for i := low(x) to high(x) do RSum := RSum + x[i]; end;
var
  f15: array[1..5] of longint = (10,20,30,40,50);   { low=1 }
  f57: array[5..7] of longint = (1,2,3);            { low=5 }
  f03: array[0..2] of longint = (7,8,9);            { low=0 }
begin
  writeln(RSum(f15), ' ', RSum(f57), ' ', RSum(f03));
end.
EOF
if run "$CC" -Fu"$RTL" -O3 -al -FE"$tmp" "$tmp/a.pp" >/dev/null 2>&1; then
  [ "$(ncalls RSUM "$tmp/a.s")" = 0 ] || fail "Part A: RSum NOT inlined (call present)"
  out="$(run "$tmp/a" 2>&1)"
  [ "$out" = "150 6 24" ] || fail "Part A: wrong output [$out] (expected '150 6 24')"
else
  fail "Part A: compile failed"
fi

# ---------------------------------------------------------------------------
# Part B: constructor, slice, open string, and passed-through open array.
# ---------------------------------------------------------------------------
cat > "$tmp/b.pp" <<'EOF'
{$mode objfpc}{$H+}
program b;
function VSum(const x: array of longint): longint; inline;
var i: longint;
begin VSum := 0; for i := low(x) to high(x) do VSum := VSum + x[i]; end;
function VThru(const x: array of longint): longint; inline;
begin VThru := VSum(x); end;                       { open array -> open array }
function VChar(const x: array of char): longint; inline;
var i: longint;
begin VChar := 0; for i := low(x) to high(x) do VChar := VChar + ord(x[i]); end;
var f: array[1..5] of longint = (10,20,30,40,50);
begin
  writeln(VSum([100,200,300]), ' ', VSum(f[2..4]), ' ', VThru(f), ' ', VChar('hi'));
end.
EOF
if run "$CC" -Fu"$RTL" -O3 -al -FE"$tmp" "$tmp/b.pp" >/dev/null 2>&1; then
  # VThru itself must inline (its own body may keep an inner VSum call -- a
  # nested-inline-level limitation, not a correctness issue).
  [ "$(ncalls VTHRU "$tmp/b.s")" = 0 ] || fail "Part B: VThru NOT inlined"
  [ "$(ncalls VCHAR "$tmp/b.s")" = 0 ] || fail "Part B: VChar NOT inlined"
  out="$(run "$tmp/b" 2>&1)"
  # constructor 600; slice f[2..4]=20+30+40=90; thru f=150; 'hi'=104+105=209
  [ "$out" = "600 90 150 209" ] || fail "Part B: wrong output [$out] (expected '600 90 150 209')"
else
  fail "Part B: compile failed"
fi

# direct constructor + slice VSum calls must inline (checked in isolation so a
# nested VThru call does not perturb the count)
cat > "$tmp/b2.pp" <<'EOF'
{$mode objfpc}
program b2;
function VSum(const x: array of longint): longint; inline;
var i: longint;
begin VSum := 0; for i := low(x) to high(x) do VSum := VSum + x[i]; end;
var f: array[1..5] of longint = (10,20,30,40,50);
begin writeln(VSum([100,200,300]), ' ', VSum(f[2..4])); end.
EOF
if run "$CC" -Fu"$RTL" -O3 -al -FE"$tmp" "$tmp/b2.pp" >/dev/null 2>&1; then
  [ "$(ncalls VSUM "$tmp/b2.s")" = 0 ] || fail "Part B2: direct VSum (constructor/slice) NOT inlined"
  out="$(run "$tmp/b2" 2>&1)"
  [ "$out" = "600 90" ] || fail "Part B2: wrong output [$out] (expected '600 90')"
else
  fail "Part B2: compile failed"
fi

# ---------------------------------------------------------------------------
# Part C: array of const inlines and evaluates correctly.
# ---------------------------------------------------------------------------
cat > "$tmp/c.pp" <<'EOF'
{$mode objfpc}
program c;
function CountPos(const a: array of const): longint; inline;
var i: longint;
begin
  CountPos := 0;
  for i := 0 to high(a) do
    if (a[i].VType = vtInteger) and (a[i].VInteger > 0) then Inc(CountPos);
end;
begin
  writeln(CountPos([1, -2, 3, 0, 5]), ' ', CountPos([-1,-2]));
end.
EOF
if run "$CC" -Fu"$RTL" -O3 -al -FE"$tmp" "$tmp/c.pp" >/dev/null 2>&1; then
  [ "$(ncalls COUNTPOS "$tmp/c.s")" = 0 ] || fail "Part C: CountPos NOT inlined"
  out="$(run "$tmp/c" 2>&1)"
  [ "$out" = "3 0" ] || fail "Part C: wrong output [$out] (expected '3 0')"
else
  fail "Part C: compile failed"
fi

# ---------------------------------------------------------------------------
# Part D: a DYNAMIC array actual STAYS out of line (note) and runs correctly.
# ---------------------------------------------------------------------------
cat > "$tmp/d.pp" <<'EOF'
{$mode objfpc}
program d;
function DSum(const x: array of longint): longint; inline;
var i: longint;
begin DSum := 0; for i := low(x) to high(x) do DSum := DSum + x[i]; end;
var dyn: array of longint;
begin
  setlength(dyn, 4);
  dyn[0] := 1; dyn[1] := 2; dyn[2] := 3; dyn[3] := 4;
  writeln(DSum(dyn));       { 10 }
end.
EOF
noteD="$(run "$CC" -Fu"$RTL" -vd -O3 -al -FE"$tmp" "$tmp/d.pp" 2>&1)"
echo "$noteD" | grep -Eq 'Not inlining "DSum", open-array parameter has a dynamic-array actual' \
  || fail "Part D: dynamic-array refusal note missing"
[ "$(ncalls DSUM "$tmp/d.s")" -ge 1 ] || fail "Part D: DSum unexpectedly inlined (no call)"
out="$(run "$tmp/d" 2>&1)"
[ "$out" = "10" ] || fail "Part D: wrong output [$out] (expected 10)"

# ---------------------------------------------------------------------------
# Part E: var open array (write-back) with a static actual inlines correctly.
# ---------------------------------------------------------------------------
cat > "$tmp/e.pp" <<'EOF'
{$mode objfpc}
program e;
procedure DoubleAll(var x: array of longint); inline;
var i: longint;
begin for i := low(x) to high(x) do x[i] := x[i] * 2; end;
var f: array[1..3] of longint = (5,6,7);
begin
  DoubleAll(f);
  writeln(f[1], ' ', f[2], ' ', f[3]);   { 10 12 14 }
end.
EOF
if run "$CC" -Fu"$RTL" -O3 -al -FE"$tmp" "$tmp/e.pp" >/dev/null 2>&1; then
  [ "$(ncalls DOUBLEALL "$tmp/e.s")" = 0 ] || fail "Part E: DoubleAll NOT inlined"
  out="$(run "$tmp/e" 2>&1)"
  [ "$out" = "10 12 14" ] || fail "Part E: wrong output [$out] (expected '10 12 14')"
else
  fail "Part E: compile failed"
fi

if [ "$rc" -eq 0 ]; then
  echo "PASS: open-array/array-of-const params inline at -O3 (static any-base re-based, constructor/slice/open-string/pass-through/var all correct, array of const inlines); dynamic-array actuals stay out of line and run correctly"
fi
exit "$rc"
