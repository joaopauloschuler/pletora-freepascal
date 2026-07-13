#!/usr/bin/env bash
# Codegen + runtime checks for inlining routines that CONTAIN nested procedures
# (checknodeinlining refusals "nested procedures" / "access to local from nested
# scope").
#
# The sound condition is exactly pio_nested_access: it is set on a routine
# whenever a nested routine reads its frame (a parent local/param, a non-local
# exit/goto, or its address taken as a nested procvar).  Such a routine still
# cannot be inlined (the nested routine is compiled once against fixed frame
# offsets that inlining would relocate).  But a routine that merely CONTAINS
# nested procedures which never touch its frame -- independent functions that
# only happen to be lexically nested -- has a dead frame and inlines soundly.
#
# This script LOCKS IN: a routine with non-capturing nested procs (incl.
# siblings calling each other, deep nesting, and nested procs with their own
# locals) inlines at -O3 (no `call` to the inline target) and is correct; while
# capturing a parent local, capturing a parent parameter, and a self-recursive
# nested proc (which needs its own frame link) all STAY out of line and remain
# correct.
#
# Usage: unleashed/tests/inline_nestedproc_check.sh [path-to-ppcx64]
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
ncalls() { grep -Ec "call[[:space:]].*_\\\$\\\$_$1\\\$" "$2" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# Part A: non-capturing nested procs (sibling call, deep nest, own local) inline.
# ---------------------------------------------------------------------------
cat > "$tmp/a.pp" <<'EOF'
{$mode objfpc}
program a;
function F1(x: longint): longint; inline;
  function A(y: longint): longint;
  begin A := y + 1; end;
  function B(y: longint): longint;
  begin B := A(y) * 2; end;                 { sibling call, no parent frame }
begin F1 := B(x); end;
function F3(x: longint): longint; inline;
  function L1(y: longint): longint;
    function L2(z: longint): longint;
    begin L2 := z * z; end;
  begin L1 := L2(y) + 1; end;               { deep nest, no parent frame }
begin F3 := L1(x); end;
function F4(x: longint): longint; inline;
  function G(y: longint): longint;
  var t: longint;
  begin t := y * 3; G := t - 1; end;        { own local, no parent frame }
begin F4 := G(x) + G(x + 1); end;
begin
  writeln(F1(10), ' ', F3(4), ' ', F4(2));  { 22 17 13 }
  writeln(F1(1),  ' ', F3(2), ' ', F4(0));  { 4 5 1 }
end.
EOF
if run "$CC" -Fu"$RTL" -O3 -al -s -FE"$tmp" "$tmp/a.pp" >/dev/null 2>&1; then
  [ "$(ncalls F1 "$tmp/a.s")" = 0 ] || fail "Part A: F1 NOT inlined (call present)"
  [ "$(ncalls F3 "$tmp/a.s")" = 0 ] || fail "Part A: F3 NOT inlined (call present)"
  [ "$(ncalls F4 "$tmp/a.s")" = 0 ] || fail "Part A: F4 NOT inlined (call present)"
  # the nested procs themselves must still be emitted + called
  [ "$(ncalls B "$tmp/a.s")" -ge 1 ] || fail "Part A: nested B not called"
fi
if run "$CC" -Fu"$RTL" -O3 -FE"$tmp" "$tmp/a.pp" >/dev/null 2>&1; then
  out="$(run "$tmp/a" 2>&1)"
  [ "$out" = $'22 17 13\n4 5 1' ] || fail "Part A: wrong output [$out] (expected '22 17 13' / '4 5 1')"
else
  fail "Part A: runnable compile failed"
fi

# ---------------------------------------------------------------------------
# Part B: nested proc reading a parent LOCAL stays out of line, still correct.
# ---------------------------------------------------------------------------
cat > "$tmp/b.pp" <<'EOF'
{$mode objfpc}
program b;
function Outer(x: longint): longint; inline;
var acc: longint;
  procedure Add(y: longint);
  begin acc := acc + y; end;                { reads parent LOCAL acc }
begin acc := 0; Add(x); Add(x * 2); Outer := acc; end;
begin writeln(Outer(5)); end.               { 5 + 10 = 15 }
EOF
noteB="$(run "$CC" -Fu"$RTL" -vn -O3 -FE"$tmp" "$tmp/b.pp" 2>&1)"
echo "$noteB" | grep -Eq 'Outer.*not inlined \(access to local from nested scope\)' \
  || fail "Part B: parent-local capture note missing"
[ "$(run "$tmp/b" 2>&1)" = 15 ] || fail "Part B: wrong output (expected 15)"

# ---------------------------------------------------------------------------
# Part C: nested proc reading a parent PARAMETER stays out of line, correct.
# ---------------------------------------------------------------------------
cat > "$tmp/c.pp" <<'EOF'
{$mode objfpc}
program c;
function Outer(x: longint): longint; inline;
  function AddX(y: longint): longint;
  begin AddX := y + x; end;                 { reads parent PARAM x }
begin Outer := AddX(10) + AddX(20); end;
begin writeln(Outer(5)); end.               { (10+5)+(20+5)=40 }
EOF
noteC="$(run "$CC" -Fu"$RTL" -vn -O3 -FE"$tmp" "$tmp/c.pp" 2>&1)"
echo "$noteC" | grep -Eq 'Outer.*not inlined \(access to local from nested scope\)' \
  || fail "Part C: parent-param capture note missing"
[ "$(run "$tmp/c" 2>&1)" = 40 ] || fail "Part C: wrong output (expected 40)"

# ---------------------------------------------------------------------------
# Part D: self-recursive nested proc (needs its own frame link) stays out.
# ---------------------------------------------------------------------------
cat > "$tmp/d.pp" <<'EOF'
{$mode objfpc}
program d;
function F(x: longint): longint; inline;
  function Fact(n: longint): longint;
  begin if n <= 1 then Fact := 1 else Fact := n * Fact(n - 1); end;
begin F := Fact(x); end;
begin writeln(F(5)); end.                   { 120 }
EOF
noteD="$(run "$CC" -Fu"$RTL" -vn -O3 -FE"$tmp" "$tmp/d.pp" 2>&1)"
echo "$noteD" | grep -Eq 'F.*not inlined \(access to local from nested scope\)' \
  || fail "Part D: recursive-nested refusal note missing"
[ "$(run "$tmp/d" 2>&1)" = 120 ] || fail "Part D: wrong output (expected 120)"

if [ "$rc" -eq 0 ]; then
  echo "PASS: routines with non-capturing nested procs (sibling/deep/own-local) inline at -O3 (no call) and are correct; parent-local, parent-param and recursive-nested captures stay out of line and run correctly"
fi
exit "$rc"
