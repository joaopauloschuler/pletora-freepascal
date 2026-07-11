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
# Part D: a DYNAMIC array actual now INLINES (no call) and runs bit-identically
# to the out-of-line reference.  The dynarray->openarray boundary (deref to the
# data pointer + runtime high=length-1) is rebuilt inside the splice.  Includes
# empty/nil dynarray actuals (high = -1) which must sum to 0.
# ---------------------------------------------------------------------------
cat > "$tmp/d.pp" <<'EOF'
{$mode objfpc}{$ifdef NOINL}{$inline off}{$endif}
program d;
function DSum(const x: array of longint): longint; inline;
var i: longint;
begin DSum := 0; for i := low(x) to high(x) do DSum := DSum + x[i]; end;
var dyn, empt: array of longint;
begin
  setlength(dyn, 4);
  dyn[0] := 1; dyn[1] := 2; dyn[2] := 3; dyn[3] := 4;
  writeln(DSum(dyn), ' ', DSum(empt));    { 10 0  (empt is nil -> high=-1) }
end.
EOF
# out-of-line reference (inlining disabled)
if run "$CC" -Fu"$RTL" -dNOINL -O3 -FE"$tmp" "$tmp/d.pp" >/dev/null 2>&1; then
  cp "$tmp/d" "$tmp/d_ref"
  refD="$(run "$tmp/d_ref" 2>&1)"
else
  fail "Part D: reference (no-inline) compile failed"; refD="?"
fi
if run "$CC" -Fu"$RTL" -O3 -al -FE"$tmp" "$tmp/d.pp" >/dev/null 2>&1; then
  [ "$(ncalls DSUM "$tmp/d.s")" = 0 ] || fail "Part D: DSum with dynamic-array actual NOT inlined (call present)"
  out="$(run "$tmp/d" 2>&1)"
  [ "$out" = "10 0" ] || fail "Part D: wrong output [$out] (expected '10 0')"
  [ "$out" = "$refD" ] || fail "Part D: inlined output [$out] != out-of-line reference [$refD]"
else
  fail "Part D: compile failed"
fi

# ---------------------------------------------------------------------------
# Part D2: MANAGED base (const array of ansistring, and a record containing an
# ansistring) with a dynamic-array actual inlines and matches the reference.
# ---------------------------------------------------------------------------
cat > "$tmp/d2.pp" <<'EOF'
{$mode objfpc}{$H+}{$ifdef NOINL}{$inline off}{$endif}
program d2;
type TR = record s: ansistring; n: longint; end;
function Cat(const a: array of ansistring): ansistring; inline;
var i: longint;
begin Cat := ''; for i := 0 to high(a) do Cat := Cat + a[i]; end;
function SumN(const a: array of TR): longint; inline;
var i: longint;
begin SumN := 0; for i := 0 to high(a) do SumN := SumN + a[i].n + length(a[i].s); end;
var ds: array of ansistring; dr: array of TR;
begin
  setlength(ds, 3); ds[0]:='foo'; ds[1]:='bar'; ds[2]:='baz';
  setlength(dr, 2); dr[0].s:='ab'; dr[0].n:=10; dr[1].s:='cde'; dr[1].n:=20;
  writeln(Cat(ds), ' ', SumN(dr));        { foobarbaz 35 }
end.
EOF
if run "$CC" -Fu"$RTL" -dNOINL -O3 -FE"$tmp" "$tmp/d2.pp" >/dev/null 2>&1; then
  cp "$tmp/d2" "$tmp/d2_ref"; refD2="$(run "$tmp/d2_ref" 2>&1)"
else fail "Part D2: reference compile failed"; refD2="?"; fi
if run "$CC" -Fu"$RTL" -O3 -al -FE"$tmp" "$tmp/d2.pp" >/dev/null 2>&1; then
  [ "$(ncalls CAT "$tmp/d2.s")" = 0 ]  || fail "Part D2: Cat (managed base) NOT inlined"
  [ "$(ncalls SUMN "$tmp/d2.s")" = 0 ] || fail "Part D2: SumN (record-with-managed base) NOT inlined"
  out="$(run "$tmp/d2" 2>&1)"
  [ "$out" = "foobarbaz 35" ] || fail "Part D2: wrong output [$out] (expected 'foobarbaz 35')"
  [ "$out" = "$refD2" ] || fail "Part D2: inlined output [$out] != reference [$refD2]"
else
  fail "Part D2: compile failed"
fi

# ---------------------------------------------------------------------------
# Part D3: a BY-VALUE open array of a managed base keeps copy-on-write correct.
# The inline copy-temp machinery cannot size an open array (tarraydef.size
# internalerror 99080501), so a by-value open-array parameter stays out of line;
# its callee-local copy must be mutated without disturbing the caller's array.
# ---------------------------------------------------------------------------
cat > "$tmp/d3.pp" <<'EOF'
{$mode objfpc}{$H+}
program d3;
function Wrap(a: array of ansistring): ansistring; inline;   { by-value, mutated }
var i: longint;
begin
  for i := 0 to high(a) do a[i] := '<'+a[i]+'>';
  Wrap := '';
  for i := 0 to high(a) do Wrap := Wrap + a[i];
end;
var d: array of ansistring;
begin
  setlength(d, 3); d[0]:='foo'; d[1]:='bar'; d[2]:='baz';
  writeln(Wrap(d));               { <foo><bar><baz> }
  writeln(d[0], d[1], d[2]);      { foobarbaz -- originals untouched (COW) }
end.
EOF
noteD3="$(run "$CC" -Fu"$RTL" -vd -O3 -al -FE"$tmp" "$tmp/d3.pp" 2>&1)"
if [ -f "$tmp/d3.s" ]; then
  echo "$noteD3" | grep -Eq 'by-value open array' \
    || fail "Part D3: by-value open-array refusal note missing"
  [ "$(ncalls WRAP "$tmp/d3.s")" -ge 1 ] || fail "Part D3: Wrap unexpectedly inlined"
  out="$(run "$tmp/d3" 2>&1)"
  [ "$out" = "$(printf '<foo><bar><baz>\nfoobarbaz')" ] \
    || fail "Part D3: wrong output / COW violated [$out]"
else
  fail "Part D3: compile failed"
fi

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
  echo "PASS: open-array/array-of-const params inline at -O3 (static any-base re-based, constructor/slice/open-string/pass-through/var all correct, array of const inlines); dynamic-array actuals (incl. managed base and empty/nil) now inline and match the out-of-line reference; by-value open arrays stay out of line with copy-on-write intact"
fi
exit "$rc"
