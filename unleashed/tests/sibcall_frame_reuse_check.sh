#!/usr/bin/env bash
# Codegen assertion for the -O4 "sibling tail-call frame reuse" peephole
# (TX86AsmOptimizer.PostPeepholeOptCall / DebugMsg "CallFrameRet2Jmp done
# (sibling tail-call frame reuse)").  This peephole is gated DIRECTLY on
# cs_opt_level4 (NOT on the -OoSIBCALL toggle), so it is exercised at plain -O4.
#
# It hoists a framed routine's teardown (leaq N(%rsp),%rsp / addq $N,%rsp plus
# optional callee-saved pops) above a tail call and turns the call into a jmp.
#
# This script proves two things at -O4:
#   * ELIGIBLE (register-only callee): the transform still FIRES -- the framed
#     routine's tail call becomes a jmp to the sibling.  (regression guard: the
#     fix for the stack-args miscompile must not disable the safe case.)
#   * STACK-ARGS (callee takes a stack-passed argument): the transform must NOT
#     fire -- releasing the frame before the jmp would leave the callee reading
#     its stack args from the released outgoing-parameter area (the blocker-#5
#     miscompile).  The tail call must stay a plain call.
#   * INDIRECT (procvar/method tail call): the transform must NOT fire -- the
#     target lives in a register the hoisted teardown may pop (jmp *poppedreg)
#     or a frame slot it releases (jmp *N(%rsp)); either way the jmp branches to
#     garbage (the second blocker-#5 hole that crashed the self-hosted compiler).
#
# Usage: unleashed/tests/sibcall_frame_reuse_check.sh [path-to-ppcx64]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ELIGIBLE: a framed routine (local array forces a leaq/addq frame teardown)
# whose tail call passes only register args (3 int64 -> rdi,rsi,rdx).
cat > "$tmp/elig.pp" <<'EOF'
program elig;
{$mode objfpc}
function inner(a,b,c : int64) : int64; noinline;
begin inner := a*b + c; end;
function outer(x : int64) : int64; noinline;
var loc : array[0..7] of int64; i : integer;
begin
  for i := 0 to 7 do loc[i] := x + i;
  outer := inner(loc[0], loc[1], loc[2]);
end;
begin
  if outer(10) <> 10*11+12 then begin writeln('FAIL'); halt(1); end;
  writeln('ok');
end.
EOF

# INDIRECT: framed routine ending in a procvar tail call whose target survives
# in a callee-saved register across the arg-computing calls -> `call *%reg`; the
# transform must fall back to a call (hoisting the teardown would pop the target).
cat > "$tmp/ind.pp" <<'EOF'
program ind;
{$mode objfpc}
type TFn = function(a,b,c : int64) : int64;
function add3(a,b,c : int64) : int64; noinline;
begin add3 := a+b+c; end;
function side(x : int64) : int64; noinline;
begin side := x*2; end;
function outer(f : TFn; x : int64) : int64; noinline;
var loc : array[0..3] of int64; i : integer;
begin
  for i := 0 to 3 do loc[i] := x + i;
  outer := f(side(loc[0]), side(loc[1]), side(loc[2]));
end;
begin
  if outer(@add3, 10) <> 66 then begin writeln('FAIL'); halt(1); end;
  writeln('ok');
end.
EOF

# STACK-ARGS: same framed shape, but the tail callee takes eight int64 args, so
# the 7th/8th are passed on the stack -> the transform must fall back to a call.
cat > "$tmp/stk.pp" <<'EOF'
program stk;
{$mode objfpc}
function inner(a,b,c,d,e,f,g,h : int64) : int64; noinline;
begin inner := a+b+c+d+e+f+g+h; end;
function outer(x : int64) : int64; noinline;
var loc : array[0..7] of int64; i : integer;
begin
  for i := 0 to 7 do loc[i] := x + i;
  outer := inner(loc[0],loc[1],loc[2],loc[3],loc[4],loc[5],loc[6],loc[7]);
end;
begin
  if outer(10) <> 108 then begin writeln('FAIL'); halt(1); end;
  writeln('ok');
end.
EOF

mkdir -p "$tmp/e" "$tmp/s" "$tmp/i"
cp "$tmp/elig.pp" "$tmp/e/"; cp "$tmp/stk.pp" "$tmp/s/"; cp "$tmp/ind.pp" "$tmp/i/"
( cd "$tmp/e" && "$CC" -Fu"$RTL" -O4 -al -s elig.pp >/dev/null 2>&1 )
( cd "$tmp/s" && "$CC" -Fu"$RTL" -O4 -al -s stk.pp  >/dev/null 2>&1 )
( cd "$tmp/i" && "$CC" -Fu"$RTL" -O4 -al -s ind.pp  >/dev/null 2>&1 )

# also build + run all to confirm correct runtime behaviour
( cd "$tmp/e" && "$CC" -Fu"$RTL" -O4 elig.pp >/dev/null 2>&1 )
( cd "$tmp/s" && "$CC" -Fu"$RTL" -O4 stk.pp  >/dev/null 2>&1 )
( cd "$tmp/i" && "$CC" -Fu"$RTL" -O4 ind.pp  >/dev/null 2>&1 )

elig_jmp=$(grep -cE 'jmp[[:space:]].*_INNER\$'  "$tmp/e/elig.s" || true)
stk_jmp=$(grep -cE  'jmp[[:space:]].*_INNER\$'  "$tmp/s/stk.s"  || true)
stk_call=$(grep -cE 'call[[:space:]].*_INNER\$' "$tmp/s/stk.s"  || true)
# an indirect tail call is `jmp *<reg|mem>` / `call *<reg|mem>`
ind_jmp=$(grep -cE  'jmp[[:space:]]+\*'  "$tmp/i/ind.s" || true)
ind_call=$(grep -cE 'call[[:space:]]+\*' "$tmp/i/ind.s" || true)
elig_out="$( cd "$tmp/e" && ulimit -v 3000000; timeout 30 ./elig || echo RUNFAIL )"
stk_out="$(  cd "$tmp/s" && ulimit -v 3000000; timeout 30 ./stk  || echo RUNFAIL )"
ind_out="$(  cd "$tmp/i" && ulimit -v 3000000; timeout 30 ./ind  || echo RUNFAIL )"

echo "ELIGIBLE (reg-only) : tail jmp=$elig_jmp (expect 1), run=$elig_out (expect ok)"
echo "STACK-ARGS          : tail jmp=$stk_jmp (expect 0), plain call=$stk_call (expect >=1), run=$stk_out (expect ok)"
echo "INDIRECT            : indirect jmp=$ind_jmp (expect 0), indirect call=$ind_call (expect >=1), run=$ind_out (expect ok)"

rc=0
[ "$elig_jmp" -eq 1 ] || { echo "FAIL: register-only tail call was NOT sibling-frame-reused (peephole stopped firing for the safe case)"; rc=1; }
[ "$elig_out" = "ok" ] || { echo "FAIL: eligible case miscompiled at runtime"; rc=1; }
[ "$stk_jmp" -eq 0 ] || { echo "FAIL: stack-args tail call WAS sibling-frame-reused (blocker-#5 miscompile)"; rc=1; }
[ "$stk_call" -ge 1 ] || { echo "FAIL: stack-args tail call did not fall back to a plain call"; rc=1; }
[ "$stk_out" = "ok" ] || { echo "FAIL: stack-args case miscompiled at runtime"; rc=1; }
[ "$ind_jmp" -eq 0 ] || { echo "FAIL: indirect tail call WAS sibling-frame-reused (blocker-#5 indirect miscompile)"; rc=1; }
[ "$ind_call" -ge 1 ] || { echo "FAIL: indirect tail call did not keep an indirect call"; rc=1; }
[ "$ind_out" = "ok" ] || { echo "FAIL: indirect case miscompiled at runtime"; rc=1; }

[ "$rc" -eq 0 ] && echo "PASS: -O4 sibling frame reuse fires for register-only direct callees and is refused for stack-arg and indirect callees"
exit "$rc"
