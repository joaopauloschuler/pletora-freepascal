#!/usr/bin/env bash
# Codegen + runtime checks for inlining a cross-unit inline routine whose body
# references a UNIT-PRIVATE (static-symtable) symbol of its defining unit
# (checknodeinlining / ncal.check_inlining refusal for pi_uses_static_symtable).
#
# optcall.importglobalsyms rebases those references at the call site (adds the
# cross-unit staticvarsym / private procsym to the caller's imported-symbol
# list), and on any target with hidden-symbol support (x86_64-linux and every
# other mainstream target) the defining unit emits those symbols as hidden
# (DSO-local) rather than truly static, so the spliced body links and runs.
# This script LOCKS THAT IN: a cross-unit inline function that reads AND mutates
# a private var, reads a private typed const, and calls an implementation-only
# procedure must actually inline (no `call` to the inline target in the caller)
# and compute correctly.
#
# The refusal survives only for targets WITHOUT tf_supports_hidden_symbols,
# where a unit-private symbol genuinely cannot be referenced from another object
# file; that path is not reachable on this host.
#
# Usage: unleashed/tests/inline_crossunit_static_check.sh [path-to-ppcx64]
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

cat > "$tmp/sunit.pas" <<'EOF'
unit sunit;
{$mode objfpc}
interface
function GetCounter: longint; inline;    { reads private var + private typed const }
procedure Bump; inline;                  { mutates private var }
function Square(x: longint): longint; inline;  { calls implementation-only proc }
implementation
var
  privCounter: longint = 100;            { static-symtable private var }
const
  privTable: array[0..3] of longint = (5,6,7,8);  { private typed const }
function helper(x: longint): longint;    { implementation-only (static) proc }
begin helper := x * x; end;
function GetCounter: longint; inline;
begin GetCounter := privCounter + privTable[2]; end;
procedure Bump; inline;
begin Inc(privCounter); end;
function Square(x: longint): longint; inline;
begin Square := helper(x); end;
end.
EOF

cat > "$tmp/emain.pp" <<'EOF'
{$mode objfpc}
program emain;
uses sunit;
begin
  writeln(GetCounter);   { 100 + 7 = 107 }
  Bump; Bump;
  writeln(GetCounter);   { 102 + 7 = 109 }
  writeln(Square(5));    { 25 }
end.
EOF

# asm-inspection build in its own dir (-s does not assemble, so keep it apart
# from the runnable build to avoid a .ppu-without-.o link clash)
mkdir -p "$tmp/asm" "$tmp/run"
if run "$CC" -Fu"$RTL" -O3 -al -s -FE"$tmp/asm" -FU"$tmp/asm" "$tmp/emain.pp" >/dev/null 2>&1; then
  [ "$(ncalls GETCOUNTER "$tmp/asm/emain.s")" = 0 ] || fail "GetCounter NOT inlined cross-unit (call present)"
  [ "$(ncalls BUMP        "$tmp/asm/emain.s")" = 0 ] || fail "Bump NOT inlined cross-unit (call present)"
  [ "$(ncalls SQUARE      "$tmp/asm/emain.s")" = 0 ] || fail "Square NOT inlined cross-unit (call present)"
  # the implementation-only helper must be imported and called directly
  [ "$(ncalls HELPER      "$tmp/asm/emain.s")" -ge 1 ] || fail "private helper proc not referenced from caller"
else
  fail "asm-inspection compile failed"
fi

# runnable build (fresh dir) to check the values
if run "$CC" -Fu"$RTL" -O3 -FE"$tmp/run" -FU"$tmp/run" "$tmp/emain.pp" >/dev/null 2>&1; then
  out="$(run "$tmp/run/emain" 2>&1)"
  [ "$out" = $'107\n109\n25' ] || fail "wrong output [$out] (expected 107 / 109 / 25)"
else
  fail "runnable compile/link failed"
fi

# no refusal note fires on this (hidden-symbol) target
note="$(run "$CC" -Fu"$RTL" -vd -O3 -FE"$tmp/run" -FU"$tmp/run" "$tmp/emain.pp" 2>&1)"
echo "$note" | grep -Eq 'unit-private symbols and target lacks hidden-symbol support' \
  && fail "cross-unit static-symtable refusal fired on a hidden-symbol target"

if [ "$rc" -eq 0 ]; then
  echo "PASS: cross-unit inline bodies referencing unit-private static symbols (var read+mutate, typed const, implementation-only proc) inline at -O3 (no call) and run correctly; refusal does not fire on this hidden-symbol target"
fi
exit "$rc"
