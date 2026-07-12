#!/usr/bin/env bash
#
# -OoSTACKGUARD codegen + runtime assertions (-fstack-protector-strong-style
# stack canaries for the native x86-64 backend).
#
# On entry to a routine whose frame holds a vulnerable object -- a local
# array/record aggregate, an address-taken local, or an inline-asm block (gcc's
# -strong selection heuristic) -- the compiler stores a secret guard word
# (FPC_STACK_CHK_GUARD, an RTL-owned global seeded once at startup; NOT the glibc
# %fs:0x28 TLS slot, because the default linux-x86_64 RTL is libc-free) into a
# dedicated 8-byte slot reserved at the very top of the local frame, between the
# locals and the saved RBP/return address.  Before every normal return it
# reloads the slot and compares it against the guard; on mismatch it branches to
# an out-of-line path that calls FPC_STACK_CHK_FAIL (prints "stack smashing
# detected" and aborts nonzero).  Pure scalar leaves are NOT instrumented so the
# switch costs virtually nothing where it cannot help.
#
# Asserts:
#   1. WITH -OoSTACKGUARD an array-local routine loads+stores FPC_STACK_CHK_GUARD
#      in the prologue and, in the epilogue, reloads it, compares (cmp + jne) and
#      the FPC_STACK_CHK_FAIL call is present.
#   2. An address-taken-local routine is likewise instrumented.
#   3. A pure scalar leaf routine is NOT instrumented (no guard reference).
#   4. WITHOUT the switch (default / -OoNOSTACKGUARD) an array-local routine has
#      no guard reference at all.
#   5. Runtime: a deliberate linear overflow of a local array past its end aborts
#      via the fail path (nonzero exit, "stack smashing" on stderr) when
#      instrumented; the identical program with the overflow line disabled runs
#      to completion (exit 0) under instrumentation.
#   6. A normal program produces bit-exact output with the switch on and off.
#
# Usage: unleashed/tests/stackguard_check.sh [path-to-ppcx64]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- one routine per file so a whole-file grep is unambiguous ---

# (A) array local -> instrumented
cat > "$tmp/arr.pp" <<'EOF'
program arr;
{$mode objfpc}{$R-}{$Q-}
function f(n: longint): longint;
var buf: array[0..31] of longint; i: longint;
begin f:=0; for i:=0 to 31 do buf[i]:=i*n; f:=buf[n and 31]; end;
begin Writeln(f(3)); end.
EOF

# (B) address-taken scalar local -> instrumented
cat > "$tmp/addr.pp" <<'EOF'
program addr;
{$mode objfpc}{$R-}{$Q-}
function f(n: longint): longint;
var x: longint; p: ^longint;
begin p:=@x; p^:=n*7; f:=x; end;
begin Writeln(f(3)); end.
EOF

# (C) pure scalar leaf -> NOT instrumented
cat > "$tmp/leaf.pp" <<'EOF'
program leaf;
{$mode objfpc}{$R-}{$Q-}
function f(a,b: longint): longint;
var t: longint;
begin t:=a*b+a-b; f:=t; end;
begin Writeln(f(3,4)); end.
EOF

compile() { # $1=src ; rest=flags -> writes ${src%.pp}.s in $tmp
  local src="$1"; shift
  ( cd "$tmp" && "$CC" -Fu"$RTL" -O2 "$@" -al -s "$src" >/dev/null 2>&1 )
}

rc=0

# ---- 1. array local WITH -OoSTACKGUARD: full prologue+epilogue instrumentation
compile arr.pp -OoSTACKGUARD
s="$tmp/arr.s"
g_ld=$(grep -cE 'FPC_STACK_CHK_GUARD' "$s" || true)     # >=2: prologue load + epilogue reload
# the slot load is normally folded into the compare, so the guard reg (r11) is
# compared either against the reloaded r10 or directly against the frame slot
g_cmp=$(grep -cE '^\s*cmpq\s+.*,%r1[01]' "$s" || true)
g_jne=$(grep -cE '^\s*jne\s' "$s" || true)
g_fail=$(grep -cE 'call\s+FPC_STACK_CHK_FAIL' "$s" || true)
echo "arr  +SG : guard=$g_ld cmp=$g_cmp jne=$g_jne fail=$g_fail (guard>=2, cmp>=1, jne>=1, fail>=1)"
[ "$g_ld"  -ge 2 ] || { echo "FAIL: array-local prologue/epilogue guard load missing"; rc=1; }
[ "$g_cmp" -ge 1 ] || { echo "FAIL: array-local canary compare missing"; rc=1; }
[ "$g_jne" -ge 1 ] || { echo "FAIL: array-local canary branch missing"; rc=1; }
[ "$g_fail" -ge 1 ] || { echo "FAIL: array-local FPC_STACK_CHK_FAIL call missing"; rc=1; }

# ---- 2. address-taken local WITH the switch: instrumented
compile addr.pp -OoSTACKGUARD
a_ld=$(grep -cE 'FPC_STACK_CHK_GUARD' "$tmp/addr.s" || true)
a_fail=$(grep -cE 'call\s+FPC_STACK_CHK_FAIL' "$tmp/addr.s" || true)
echo "addr +SG : guard=$a_ld fail=$a_fail (both >=1)"
[ "$a_ld" -ge 2 ] || { echo "FAIL: address-taken local not instrumented"; rc=1; }
[ "$a_fail" -ge 1 ] || { echo "FAIL: address-taken local fail path missing"; rc=1; }

# ---- 3. pure scalar leaf WITH the switch: NOT instrumented (-strong skip)
compile leaf.pp -OoSTACKGUARD
l_ld=$(grep -cE 'FPC_STACK_CHK_GUARD' "$tmp/leaf.s" || true)
echo "leaf +SG : guard=$l_ld (must be 0 -- scalar leaf skipped)"
[ "$l_ld" -eq 0 ] || { echo "FAIL: scalar leaf was instrumented (should be skipped by -strong)"; rc=1; }

# ---- 4. array local WITHOUT the switch: no instrumentation at all
compile arr.pp -OoNOSTACKGUARD
n_ld=$(grep -cE 'FPC_STACK_CHK_GUARD|FPC_STACK_CHK_FAIL' "$tmp/arr.s" || true)
echo "arr  -SG : guard/fail=$n_ld (must be 0)"
[ "$n_ld" -eq 0 ] || { echo "FAIL: guard emitted without -OoSTACKGUARD"; rc=1; }

# ---- 5. runtime: deliberate overflow aborts; clean variant completes ----
cat > "$tmp/smash.pp" <<'EOF'
program smash;
{$mode objfpc}{$R-}{$Q-}
procedure victim(n: longint);
var buf: array[0..7] of byte; i: longint;
begin
  for i:=0 to 7+n do buf[i]:=byte(i);      { writes n bytes past the buffer }
  if buf[0]=255 then Writeln('unreachable');
end;
begin victim(24); Writeln('main completed'); end.
EOF
( cd "$tmp" && "$CC" -Fu"$RTL" -O2 -OoSTACKGUARD -osmash smash.pp >/dev/null 2>&1 )
set +e
sout="$( (ulimit -v 3000000; timeout 20 "$tmp/smash" 2>&1) )"; scode=$?
set -e
echo "smash run : exit=$scode msg=[$(echo "$sout" | grep -o 'stack smashing' | head -1)] (exit!=0, 'main completed' absent)"
[ "$scode" -ne 0 ] || { echo "FAIL: overflow did not abort"; rc=1; }
echo "$sout" | grep -q 'stack smashing' || { echo "FAIL: fail handler did not report stack smashing"; rc=1; }
echo "$sout" | grep -q 'main completed' && { echo "FAIL: program continued past the smashed frame"; rc=1; }

# same program with the overflow disabled: runs to completion under the switch
sed 's/0 to 7+n/0 to 7/' "$tmp/smash.pp" > "$tmp/clean.pp"
( cd "$tmp" && "$CC" -Fu"$RTL" -O2 -OoSTACKGUARD -oclean clean.pp >/dev/null 2>&1 )
set +e
cout="$( (ulimit -v 3000000; timeout 20 "$tmp/clean") )"; ccode=$?
set -e
echo "clean run : exit=$ccode (must be 0, 'main completed')"
{ [ "$ccode" -eq 0 ] && echo "$cout" | grep -q 'main completed'; } || { echo "FAIL: instrumented non-overflowing program did not complete"; rc=1; }

# ---- 6. bit-exact output with the switch on vs off ----
cat > "$tmp/norm.pp" <<'EOF'
program norm;
{$mode objfpc}{$R-}{$Q-}
function work(n: longint): longint;
var a: array[0..63] of longint; i: longint;
begin a[0]:=1; for i:=1 to 63 do a[i]:=(a[i-1]*1103515245+12345) and $7fffffff; work:=a[n and 63]; end;
var i: longint; s: int64;
begin s:=0; for i:=0 to 999 do s:=s+work(i); Writeln(s); end.
EOF
( cd "$tmp" && "$CC" -Fu"$RTL" -O2 -oon  norm.pp >/dev/null 2>&1 && "$tmp/on"  > "$tmp/on.out"  2>&1 ) || true
( cd "$tmp" && "$CC" -Fu"$RTL" -O2 -OoSTACKGUARD -ooff norm.pp >/dev/null 2>&1 && "$tmp/off" > "$tmp/off.out" 2>&1 ) || true
if diff -q "$tmp/on.out" "$tmp/off.out" >/dev/null 2>&1; then
  echo "bitexact : identical output with -OoSTACKGUARD on/off ($(cat "$tmp/on.out"))"
else
  echo "FAIL: output differs with the switch on vs off"; rc=1
fi

[ "$rc" -eq 0 ] && echo "stackguard_check: PASS" || echo "stackguard_check: FAIL"
exit $rc
