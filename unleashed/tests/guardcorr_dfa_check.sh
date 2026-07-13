#!/usr/bin/env bash
# Precision checks for the -O4 correlated if-guard DFA false-positive suppression
# (compiler/optdfa.pas CollectCorrelatedGuardSyms, wired in compiler/psub.pas).
#
# The DFA at -O3/-O4 spuriously reports a scalar local "does not seem to be
# initialized" when it is assigned under `if COND then ...` and later read under
# a second `if COND then ...` guarded by the SAME boolean, with COND unchanged in
# between (self-host blocker on compiler/pstatmnt.pas remaining_sym).  The fix
# suppresses that WARNING only for the provably-safe correlated-guard shape; it
# must NOT hide genuine uninitialized reads, and must not touch codegen.
#
# Part A: the false-positive shapes compile clean at -O4 -Sew (warning would be
#         a fatal error) and run correctly.
# Part B: genuine uninitialized reads STILL warn (guard against over-suppression):
#         a guard on a DIFFERENT variable, a guard reassigned between the two ifs,
#         and an extra uncovered (unguarded) read.
#
# Usage: unleashed/tests/guardcorr_dfa_check.sh [path-to-ppcx64]
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

rc=0
fail() { echo "FAIL: $*"; rc=1; }

# compile $1 at flags $2 ; echo the "not initialized" note lines (may be empty)
notes() {
  ( ulimit -v 3000000; timeout 60 "$CC" -Fu"$RTL" $2 -o"$tmp/e" "$1" ) 2>&1 \
    | grep -iE 'does not seem to be initialized'
}

# ---------------------------------------------------------------------------
# Part A: correlated-guard shapes must be silent (and compile + run) at -O4.
# ---------------------------------------------------------------------------

# A1: param guard, intervening loop, read under the same guard.
cat > "$tmp/good1.pp" <<'EOF'
{$mode objfpc}
function compute(enabled : boolean; base : int64) : int64;
var remaining, acc : int64; i : integer;
begin
  acc := 0;
  if enabled then remaining := base;
  for i := 1 to 3 do acc := acc + i;
  if enabled then
    begin acc := acc + remaining; remaining := remaining - 1; acc := acc + remaining; end;
  compute := acc;
end;
begin
  if compute(true,100)<>205 then begin writeln('FAIL true'); halt(1); end;
  if compute(false,100)<>6 then begin writeln('FAIL false'); halt(1); end;
  writeln('ok');
end.
EOF

# A2: plain-local guard, second guard has an else arm that does NOT read the var.
cat > "$tmp/good2.pp" <<'EOF'
{$mode objfpc}
function pick(flag : boolean; n : int64) : int64;
var sel : int64; on : boolean;
begin
  on := flag;
  if on then sel := n * 2;
  if on then pick := sel + 1 else pick := 0;
end;
begin
  if pick(true,10)<>21 then begin writeln('FAIL true'); halt(1); end;
  if pick(false,10)<>0 then begin writeln('FAIL false'); halt(1); end;
  writeln('ok');
end.
EOF

for g in good1 good2; do
  n="$(notes "$tmp/$g.pp" "-O4 -Sew")"
  if [ -n "$n" ]; then fail "$g: correlated-guard shape still warns at -O4:"; echo "$n"; fi
  if [ -x "$tmp/e" ]; then
    out="$( ulimit -v 3000000; timeout 30 "$tmp/e" )"
    [ "$out" = "ok" ] || fail "$g: wrong runtime result: '$out'"
  else
    fail "$g: did not compile at -O4 -Sew"
  fi
done

# ---------------------------------------------------------------------------
# Part B: genuine uninitialized reads must STILL warn (no over-suppression).
# ---------------------------------------------------------------------------

# B1: defined under guard a, read under a DIFFERENT guard b.
cat > "$tmp/bad1.pp" <<'EOF'
{$mode objfpc}
function f(a,b : boolean; base : int64) : int64;
var r, acc : int64; i : integer;
begin
  acc := 0;
  if a then r := base;
  for i := 1 to 3 do acc := acc + i;
  if b then acc := acc + r;
  f := acc;
end;
begin writeln(f(true,true,1)); end.
EOF

# B2: guard reassigned between the two ifs.
cat > "$tmp/bad2.pp" <<'EOF'
{$mode objfpc}
function f(a : boolean; base : int64) : int64;
var r, acc : int64; i : integer;
begin
  acc := 0;
  if a then r := base;
  a := not a;
  for i := 1 to 3 do acc := acc + i;
  if a then acc := acc + r;
  f := acc;
end;
begin writeln(f(true,1)); end.
EOF

# B3: an extra unconditional (uncovered) read defeats the whitelist.
cat > "$tmp/bad3.pp" <<'EOF'
{$mode objfpc}
function f(a : boolean; base : int64) : int64;
var r, acc : int64;
begin
  acc := 0;
  if a then r := base;
  if a then acc := acc + r;
  acc := acc + r;
  f := acc;
end;
begin writeln(f(true,1)); end.
EOF

for b in bad1 bad2 bad3; do
  n="$(notes "$tmp/$b.pp" "-O4")"
  [ -n "$n" ] || fail "$b: genuine uninitialized read no longer warns (over-suppressed)"
done

[ "$rc" -eq 0 ] && echo "PASS: correlated-guard silent at -O4; genuine uninitialized reads still warn"
exit "$rc"
