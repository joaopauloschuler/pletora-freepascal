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
# A DYNAMIC array actual has the dynarray->openarray boundary rebuilt in the
# splice (ncal.replaceparaload) and inlines too.  A BY-VALUE open array / array
# of const also inlines: its private runtime-length copy is built at the call
# boundary (copy_value_by_ref_para, forinline=true) -- element count from the
# hidden high parameter, element-wise copy, managed elements ref-counted and
# finalized so copy-on-write and heaptrc stay correct.
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
# Part D3: a BY-VALUE open array now INLINES.  The private runtime-length copy
# is built target-neutrally at the call boundary (copy_value_by_ref_para with
# forinline=true): element count from the hidden high parameter, an element-wise
# copy, and -- for a managed base (array of AnsiString) -- the copied elements
# ref-counted and finalized.  Assert, for STATIC, DYNAMIC and SLICE actuals:
#   * the call disappears (no `call` to the routine),
#   * output is bit-identical to the out-of-line (-dNOINL) reference,
#   * mutating the callee-local copy does NOT leak back to the caller's array
#     (value semantics), and
#   * a managed base leaves no leaks under -gh (heaptrc reports 0 unfreed).
# ---------------------------------------------------------------------------
cat > "$tmp/d3.pp" <<'EOF'
{$mode objfpc}{$H+}{$ifdef NOINL}{$inline off}{$endif}
program d3;
{ managed base, by-value, mutated }
function Wrap(a: array of ansistring): ansistring; inline;
var i: longint;
begin
  for i := 0 to high(a) do a[i] := '<'+a[i]+'>';
  Wrap := '';
  for i := 0 to high(a) do Wrap := Wrap + a[i];
end;
{ non-managed base, by-value, mutated }
function DSum(a: array of longint): longint; inline;
var i: longint;
begin DSum := 0; for i := 0 to high(a) do begin a[i] := a[i]*2; DSum := DSum + a[i]; end; end;
var
  ms: array[0..2] of ansistring = ('foo','bar','baz');   { static managed }
  md: array of ansistring;                               { dynamic managed }
  ls: array[1..3] of longint = (5,6,7);                  { static non-zero base }
  ld: array of longint;                                  { dynamic }
begin
  setlength(md, 3); md[0]:='aa'; md[1]:='bb'; md[2]:='cc';
  setlength(ld, 3); ld[0]:=10; ld[1]:=20; ld[2]:=30;
  { static / dynamic / slice actuals, managed and non-managed }
  writeln(Wrap(ms), ' | ', ms[0], ms[1], ms[2]);          { copy mutated, originals intact }
  writeln(Wrap(md), ' | ', md[0], md[1], md[2]);
  writeln(Wrap(md[0..1]), ' | ', md[0], md[1], md[2]);
  writeln(DSum(ls), ' | ', ls[1], ' ', ls[2], ' ', ls[3]);
  writeln(DSum(ld), ' | ', ld[0], ' ', ld[1], ' ', ld[2]);
  writeln(DSum(ls[1..2]), ' | ', ls[1], ' ', ls[2], ' ', ls[3]);
end.
EOF
# out-of-line reference
if run "$CC" -Fu"$RTL" -dNOINL -O3 -FE"$tmp" "$tmp/d3.pp" >/dev/null 2>&1; then
  cp "$tmp/d3" "$tmp/d3_ref"; refD3="$(run "$tmp/d3_ref" 2>&1)"
else fail "Part D3: reference (no-inline) compile failed"; refD3="?"; fi
if run "$CC" -Fu"$RTL" -O3 -al -FE"$tmp" "$tmp/d3.pp" >/dev/null 2>&1; then
  [ "$(ncalls WRAP "$tmp/d3.s")" = 0 ] || fail "Part D3: Wrap (by-value) NOT inlined (call present)"
  [ "$(ncalls DSUM "$tmp/d3.s")" = 0 ] || fail "Part D3: DSum (by-value) NOT inlined (call present)"
  out="$(run "$tmp/d3" 2>&1)"
  exp="$(printf '<foo><bar><baz> | foobarbaz\n<aa><bb><cc> | aabbcc\n<aa><bb> | aabbcc\n36 | 5 6 7\n120 | 10 20 30\n22 | 5 6 7')"
  [ "$out" = "$exp" ] || fail "Part D3: wrong output / value semantics violated [$out]"
  [ "$out" = "$refD3" ] || fail "Part D3: inlined output != out-of-line reference"
else
  fail "Part D3: inline compile failed"
fi
# managed base leaves no leaks under -gh (heaptrc)
cat > "$tmp/d3h.pp" <<'EOF'
{$mode objfpc}{$H+}
program d3h;
function Wrap(a: array of ansistring): ansistring; inline;
var i: longint;
begin
  for i := 0 to high(a) do a[i] := '<'+a[i]+'>';
  Wrap := '';
  for i := 0 to high(a) do Wrap := Wrap + a[i];
end;
var ms: array[0..2] of ansistring = ('foo','bar','baz'); md, e: array of ansistring;
begin
  setlength(md, 3); md[0]:='aa'; md[1]:='bb'; md[2]:='cc';
  writeln(Wrap(ms), Wrap(md), Wrap(md[0..1]), '[', Wrap(e), ']');  { incl empty/nil }
end.
EOF
if run "$CC" -Fu"$RTL" -O3 -gh -FE"$tmp" "$tmp/d3h.pp" >/dev/null 2>&1; then
  ghout="$(run "$tmp/d3h" 2>&1)"
  echo "$ghout" | grep -Eq '(^|[^0-9])0 unfreed memory blocks' \
    || fail "Part D3: heaptrc reports leaks for a managed by-value copy [$(echo "$ghout" | grep -i unfreed)]"
else
  fail "Part D3: -gh compile failed"
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
  echo "PASS: open-array/array-of-const params inline at -O3 (static any-base re-based, constructor/slice/open-string/pass-through/var all correct, array of const inlines); dynamic-array actuals (incl. managed base and empty/nil) inline and match the out-of-line reference; by-value open arrays now inline too (static/dynamic/slice, managed and non-managed) with a runtime-length private copy -- value semantics preserved, bit-identical to the out-of-line reference, heaptrc-clean under -gh"
fi
exit "$rc"
