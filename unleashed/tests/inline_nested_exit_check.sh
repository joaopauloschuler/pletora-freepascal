#!/usr/bin/env bash
# Codegen + runtime checks for inlining routines whose body contains an
# ordinary `exit` / `exit(value)` inside a NESTED CONSTRUCT (loop / if / case /
# try..finally).
#
# checknodeinlining (compiler/psub.pas) refusal (a) was filed against
# pi_has_nested_exit.  The important, common case -- a routine marked `inline`
# that does `if c then exit(v)` inside a loop/if -- is already handled soundly
# by the inliner: the spliced body carries nf_block_with_exit, so every exit in
# it is lowered to a jump to the PER-INLINE-SITE exit label (not the caller's),
# and exit(value) first assigns the funcret temp (texitnode.pass_typecheck).
# This script LOCKS THAT IN: the routine must actually inline at -O2 (its
# out-of-line label may still be emitted, but there must be NO `call` to it) and
# compute correctly for BOTH the early-exit and the fall-through outcome.
#
# pi_has_nested_exit itself is set ONLY by the MacPas non-local
# `Exit(EnclosingRoutine)` form, which longjmp/label-jumps out to a specific
# enclosing frame and is inherently nested-scope -- splicing it into an
# arbitrary caller is unsound, so it STAYS refused.  Part D proves that shape
# still compiles and runs correctly (out-of-line).
#
# Usage: unleashed/tests/inline_nested_exit_check.sh [path-to-ppcx64]
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

rc=0
fail() { echo "FAIL: $*"; rc=1; }

run() { ulimit -v 3000000; timeout 60 "$@"; }

# a `call` to the inline target's mangled infix (…_$$_SUMUPTO…) means NOT inlined
calls_target() { grep -Eq 'call[[:space:]].*_\$\$_SUMUPTO' "$1"; }

# ---------------------------------------------------------------------------
# Part A: exit(value) inside an if inside a for-loop must inline at -O2
# ---------------------------------------------------------------------------
cat > "$tmp/a.pp" <<'EOF'
{$mode objfpc}
program a;
function sumupto(c: longint): longint; inline;
var i: longint;
begin
  sumupto := 0;
  for i := 1 to 10 do
    begin
      sumupto := sumupto + i;
      if i = c then
        exit(sumupto * 2);      { early exit with value, inside if inside loop }
    end;
  sumupto := 999;               { fall-through outcome }
end;
begin
  writeln(sumupto(3));          { 1+2+3=6 -> exit 12 }
  writeln(sumupto(20));         { no hit -> 999 }
end.
EOF
if run "$CC" -Fu"$RTL" -O2 -al -FE"$tmp" "$tmp/a.pp" >/dev/null 2>&1; then
  if calls_target "$tmp/a.s"; then
    fail "Part A: sumupto NOT inlined at -O2 (call to target present)"
  fi
  out="$(run "$tmp/a" 2>&1)"
  [ "$out" = $'12\n999' ] || fail "Part A: wrong output [$out] (expected 12 / 999)"
else
  fail "Part A: compile failed"
fi

# ---------------------------------------------------------------------------
# Part B: bare exit + exit(value) inside a while and inside a case, both inline
# ---------------------------------------------------------------------------
cat > "$tmp/b.pp" <<'EOF'
{$mode objfpc}
program b;
function sumupto(c: longint): longint; inline;
var i: longint;
begin
  sumupto := 0;
  i := 0;
  while i < 10 do
    begin
      inc(i);
      case i of
        7: if c = 7 then exit(sumupto);     { exit(value) in case in while }
      else
        sumupto := sumupto + i;
      end;
      if (c = 0) and (i = 5) then
        exit;                                { bare exit keeps current result }
    end;
  sumupto := sumupto + 1000;
end;
begin
  writeln(sumupto(7));    { adds 1..6 =21, then i=7 exit -> 21 }
  writeln(sumupto(0));    { adds 1..4=10 (i=5 -> case else adds 5 =15), i=5 bare exit -> 15 }
  writeln(sumupto(99));   { i=7 hits the case arm but c<>7 so nothing added for 7: 1..10 minus 7 =48 +1000 =1048 }
end.
EOF
if run "$CC" -Fu"$RTL" -O2 -al -FE"$tmp" "$tmp/b.pp" >/dev/null 2>&1; then
  if calls_target "$tmp/b.s"; then
    fail "Part B: sumupto NOT inlined at -O2 (call to target present)"
  fi
  out="$(run "$tmp/b" 2>&1)"
  [ "$out" = $'21\n15\n1048' ] || fail "Part B: wrong output [$out] (expected 21 / 15 / 1048)"
else
  fail "Part B: compile failed"
fi

# ---------------------------------------------------------------------------
# Part C: exit(value) inside try..finally still runs correctly (finally runs)
# ---------------------------------------------------------------------------
cat > "$tmp/c.pp" <<'EOF'
{$mode objfpc}
program c;
var g: longint;
function sumupto(k: longint): longint; inline;
begin
  sumupto := 0;
  try
    sumupto := 1;
    if k > 0 then exit(7);   { exit out of try -> finally must still run }
    sumupto := 2;
  finally
    inc(g);
  end;
end;
begin
  g := 0;
  writeln(sumupto(5), ' ', sumupto(-1), ' ', g);  { 7 2 2 }
end.
EOF
if run "$CC" -Fu"$RTL" -O2 -FE"$tmp" "$tmp/c.pp" >/dev/null 2>&1; then
  out="$(run "$tmp/c" 2>&1)"
  [ "$out" = "7 2 2" ] || fail "Part C: wrong output [$out] (expected '7 2 2')"
else
  fail "Part C: compile failed"
fi

# ---------------------------------------------------------------------------
# Part D: MacPas non-local Exit(EnclosingRoutine) stays refused but runs right
# ---------------------------------------------------------------------------
cat > "$tmp/d.pp" <<'EOF'
program d;
{$mode macpas}
function Outer(c: longint): longint;
  function Inner(x: longint): longint;
  begin
    Inner := x;
    if x > 5 then exit(Outer);   { non-local exit -> jumps out of Outer }
  end;
begin
  Outer := Inner(c) + 100;
end;
begin
  writeln(Outer(3));   { Inner(3)=3, no non-local exit -> 103 }
  writeln(Outer(9));   { Inner(9): x>5 -> Exit(Outer): Outer result stays 0 }
end.
EOF
if run "$CC" -Fu"$RTL" -O2 -FE"$tmp" "$tmp/d.pp" >/dev/null 2>&1; then
  out="$(run "$tmp/d" 2>&1)"
  [ "$out" = $'103\n0' ] || fail "Part D: wrong output [$out] (expected 103 / 0)"
else
  fail "Part D: compile failed"
fi

if [ "$rc" -eq 0 ]; then
  echo "PASS: ordinary exit/exit(value) inside nested constructs inlines at -O2 (no call) and is correct for both outcomes; try..finally exit and MacPas non-local exit run correctly"
fi
exit "$rc"
