#!/usr/bin/env bash
# Precision checks for the -O4 loop-fill DFA false-positive suppression
# (compiler/optdfa.pas CollectLoopFillCoveredSyms, wired in compiler/psub.pas).
#
# The DFA at -O3/-O4 spuriously reports a local array "does not seem to be
# initialized" when it is element-filled in one counted for-loop and element-read
# in later for-loops (self-host blocker on compiler/optfinalvalue.pas).  The fix
# suppresses that WARNING only for the provably-safe matched loop-fill shape; it
# must NOT hide genuine uninitialized reads, and must not touch codegen.
#
# Part A: the false-positive shapes compile clean at -O4 -Sew (warning would be
#         a fatal error).
# Part B: genuine uninitialized reads STILL warn (guard against over-suppression).
#
# Usage: unleashed/tests/loopfill_dfa_check.sh [path-to-ppcx64]
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
# Part A: matched loop-fill shapes must be silent (and compile) at -O4.
# ---------------------------------------------------------------------------

# A1: fill via out-param, inner subrange read arr[j], several identical readers.
cat > "$tmp/good1.pp" <<'EOF'
{$mode objfpc}
program good1;
type taccrec = record sym, cexpr : pointer; neg : boolean; end;
function match(i : integer; out a : taccrec) : boolean;
begin a.sym := pointer(ptruint(i)); a.cexpr := nil; a.neg := (i and 1)=0; match := i<>3; end;
function test(cnt : integer) : ptruint;
var k,j : integer; accs : array[0..63] of taccrec;
begin
  test := 0;
  if (cnt<=0) or (cnt>64) then exit;
  for k := 0 to cnt-1 do
    begin
      if not match(k, accs[k]) then exit;
      for j := 0 to k-1 do if accs[j].sym = accs[k].sym then exit;
    end;
  for k := 0 to cnt-1 do if assigned(accs[k].cexpr) then exit;
  for k := 0 to cnt-1 do if accs[k].neg then inc(test, ptruint(accs[k].sym));
end;
begin writeln(test(3)); end.
EOF

# A2: plain fill loop then plain read loop, identical bounds.
cat > "$tmp/good2.pp" <<'EOF'
{$mode objfpc}
program good2;
type r = record p : pointer; end;
function mk(i : integer; out a : r) : boolean;
begin a.p := pointer(ptruint(i)); mk := true; end;
function test(n : integer) : ptruint;
var k : integer; arr : array[0..63] of r;
begin
  test := 0;
  if (n<=0) or (n>64) then exit;
  for k := 0 to n-1 do if not mk(k, arr[k]) then exit;
  for k := 0 to n-1 do inc(test, ptruint(arr[k].p));
end;
begin writeln(test(4)); end.
EOF

for g in good1 good2; do
  n="$(notes "$tmp/$g.pp" "-O4 -Sew")"
  if [ -n "$n" ]; then fail "$g: matched loop-fill still warns at -O4:"; echo "$n"; fi
  [ -x "$tmp/e" ] || fail "$g: did not compile at -O4 -Sew"
done

# ---------------------------------------------------------------------------
# Part B: genuine uninitialized reads must STILL warn (no over-suppression).
# ---------------------------------------------------------------------------

# B1: fill 0..n-1 but read 0..m-1 (different bounds) -> may read unwritten.
cat > "$tmp/bad1.pp" <<'EOF'
{$mode objfpc}
program bad1;
type r = record p : pointer; end;
function mk(i : integer; out a : r) : boolean;
begin a.p := pointer(ptruint(i)); mk := true; end;
function test(n, m : integer) : ptruint;
var k : integer; arr : array[0..63] of r;
begin
  test := 0;
  if (n<=0) or (n>64) or (m<=0) or (m>64) then exit;
  for k := 0 to n-1 do if not mk(k, arr[k]) then exit;
  for k := 0 to m-1 do inc(test, ptruint(arr[k].p));
end;
begin writeln(test(3,5)); end.
EOF

# B2: no fill at all, read arr[k].
cat > "$tmp/bad2.pp" <<'EOF'
{$mode objfpc}
program bad2;
type r = record p : pointer; end;
function test(n : integer) : ptruint;
var k : integer; arr : array[0..63] of r;
begin
  test := 0;
  if (n<=0) or (n>64) then exit;
  for k := 0 to n-1 do inc(test, ptruint(arr[k].p));
end;
begin writeln(test(4)); end.
EOF

for b in bad1 bad2; do
  n="$(notes "$tmp/$b.pp" "-O4")"
  [ -n "$n" ] || fail "$b: genuine uninitialized read no longer warns (over-suppressed)"
done

[ "$rc" -eq 0 ] && echo "PASS: matched loop-fill silent at -O4; genuine uninitialized reads still warn"
exit "$rc"
