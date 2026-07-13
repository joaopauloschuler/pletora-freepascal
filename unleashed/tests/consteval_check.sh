#!/usr/bin/env bash
# -OoCONSTEVAL codegen + soundness assertions.
#
# -OoCONSTEVAL interprets the stashed body of a routine that -OoPURE has proven
# "const" (result depends only on its by-value parameters) at compile time when
# every actual is a compile-time ordinal constant, and REPLACES the whole call
# node with the computed literal.  This proves:
#   (1) a scalar helper call with a constant argument disappears -- zero call
#       instructions to it remain;
#   (2) a within-cap recursive factorial call from the main body folds -- only
#       the ONE in-body self-recursion call survives, the main call is gone, and
#       the exact literal (720) is emitted;
#   (3) a call to a used-unit callee recovered via its PPU (streamed body + the
#       optsum_pure const verdict) folds in the caller's object;
#   (4) an over-budget evaluation (exponential fib) refuses and stays a call;
#   (5) a non-const callee (reads a global) is never folded;
#   (6) a non-constant actual is never folded;
#   (7) nothing folds when the switch is off (byte-identical baseline), and the
#       optimized and unoptimized programs produce identical output;
#   (8) -OoREPORT emits a "folded" remark per site and a refusal remark (with a
#       reason) for a near-miss call to a const routine.
#
# Usage: unleashed/tests/consteval_check.sh [path-to-ppcx64]
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

# Used unit exporting a const routine (its body is streamed as inlininginfo and
# its const verdict rides the optsum_pure PPU summary).
cat > cu.pas <<'EOF'
unit cu;
{$mode objfpc}{$H+}
interface
function addk(a, b: longint): longint;
implementation
function addk(a, b: longint): longint;
begin
  result := a * b + a - b;
end;
end.
EOF

# Main program.  chelper/cfact are folded (const, constant args); cfib(38) is
# over budget; cglob reads a global (not const); ctripl gets a variable (not a
# constant actual).
cat > main.pas <<'EOF'
program main;
{$mode objfpc}{$H+}{$Q-}{$R-}
uses cu;
var g: longint = 7;

function chelper(x: longint): longint;
begin
  result := x * 2 + 1;
end;

function cfact(n: longint): longint;
begin
  if n <= 1 then result := 1 else result := n * cfact(n - 1);
end;

function cfib(n: longint): longint;
begin
  if n < 2 then result := n else result := cfib(n - 1) + cfib(n - 2);
end;

function cglob(x: longint): longint;
begin
  result := x + g;         { reads a global -> not const }
end;

function ctripl(x: longint): longint;
begin
  result := x * 3;
end;

{ iterative factorial: a plain counted for-loop. Proven const only because
  -OoPURE now treats the lowered counter step (temp writes + an unchecked
  inc/succ on a local counter) as a non-side-effect; folded by the loop-body
  evaluator (never reachable when a loop kept the routine impure). }
function cloopfact(n: longint): longint;
var i, r: longint;
begin
  r := 1;
  for i := 2 to n do r := r * i;
  cloopfact := r;
end;

var v: longint;
begin
  v := 11;
  Writeln(chelper(20));    { folds -> 41 }
  Writeln(cfact(6));       { folds -> 720 }
  Writeln(addk(6, 7));     { cross-unit fold -> 41 }
  Writeln(cfib(38));       { over budget -> stays a call }
  Writeln(cglob(3));       { not const -> stays a call }
  Writeln(ctripl(v));      { non-constant actual -> stays a call }
  Writeln(cloopfact(7));   { for-loop body folds -> 5040 }
end.
EOF

FLAGS="-Fu$RTL -Fu. -FU. -O2 -OoCONSTEVAL"

# --- ON build: keep the .s (assemble+link too so we get a runnable binary) ---
"$CC" $FLAGS -a cu.pas                       >cu.log   2>&1
"$CC" $FLAGS -a -OoREPORT main.pas -omain_on >main.log 2>&1
link_ok=$?

# call-instruction counts in the caller's object
n_chelper=$(grep -ciE 'call[^A-Za-z0-9_]+.*CHELPER' main.s)
n_addk=$(grep -ciE 'call[^A-Za-z0-9_]+.*ADDK'    main.s)
n_cfact=$(grep -ciE 'call[^A-Za-z0-9_]+.*CFACT'  main.s)
n_cfib=$(grep -ciE  'call[^A-Za-z0-9_]+.*CFIB'   main.s)
n_cglob=$(grep -ciE 'call[^A-Za-z0-9_]+.*CGLOB'  main.s)
n_ctripl=$(grep -ciE 'call[^A-Za-z0-9_]+.*CTRIPL' main.s)
n_cloopfact=$(grep -ciE 'call[^A-Za-z0-9_]+.*CLOOPFACT' main.s)
has_720=$(grep -ciE '\$720\b' main.s)
has_5040=$(grep -ciE '\$5040\b' main.s)

# report remarks
r_folded=$(grep -ciE 'consteval: call to .* folded to compile-time constant' main.log)
r_refuse=$(grep -ciE 'consteval: call to .* not folded:' main.log)

on_out=$( ( ulimit -v 3000000; timeout 60 ./main_on ) 2>/dev/null )

# --- OFF build (baseline; nothing folds) ---
rm -f ./*.o ./*.ppu ./*.s
"$CC" -Fu"$RTL" -Fu. -FU. -O2 -a cu.pas                >/dev/null 2>&1
"$CC" -Fu"$RTL" -Fu. -FU. -O2 -a main.pas -omain_off   >/dev/null 2>&1
off_chelper=$(grep -ciE 'call[^A-Za-z0-9_]+.*CHELPER' main.s)
off_addk=$(grep -ciE    'call[^A-Za-z0-9_]+.*ADDK'    main.s)
off_out=$( ( ulimit -v 3000000; timeout 60 ./main_off ) 2>/dev/null )

echo "(1) scalar helper calls: on=$n_chelper (expect 0)  off=$off_chelper (expect >=1)"
echo "(2) recursive factorial calls: on=$n_cfact (expect 1: only in-body recursion)  \$720 literal=$has_720"
echo "(3) cross-unit used-unit call: on=$n_addk (expect 0)  off=$off_addk (expect >=1)"
echo "(4) over-budget fib calls: on=$n_cfib (expect >=3: 2 recursion + 1 unfolded)"
echo "(5) non-const (global read) calls: on=$n_cglob (expect >=1)"
echo "(6) non-constant actual calls: on=$n_ctripl (expect >=1)"
echo "(6b) for-loop-body fold calls: on=$n_cloopfact (expect 0)  \$5040 literal=$has_5040"
echo "(7) run: on=[$on_out] off=[$off_out] link_rc=$link_ok (must match, rc 0)"
echo "(8) report: folded remarks=$r_folded (expect >=3)  refusal remarks=$r_refuse (expect >=1)"

fail=0
[ "$link_ok" -eq 0 ]                  || { echo "  X ON link failed"; cat main.log; fail=1; }
[ "$n_chelper" -eq 0 ]                || { echo "  X scalar helper call not folded away"; fail=1; }
[ "$off_chelper" -ge 1 ]             || { echo "  X baseline should keep the helper call"; fail=1; }
[ "$n_cfact" -eq 1 ]                  || { echo "  X factorial main call not folded (or recursion count off)"; fail=1; }
[ "$has_720" -ge 1 ]                  || { echo "  X folded factorial literal 720 absent"; fail=1; }
[ "$n_addk" -eq 0 ]                   || { echo "  X cross-unit call not folded"; fail=1; }
[ "$off_addk" -ge 1 ]                || { echo "  X baseline should keep the cross-unit call"; fail=1; }
[ "$n_cfib" -ge 3 ]                   || { echo "  X over-budget fib call was folded (unsound)"; fail=1; }
[ "$n_cglob" -ge 1 ]                  || { echo "  X non-const callee was folded (unsound)"; fail=1; }
[ "$n_ctripl" -ge 1 ]                 || { echo "  X non-constant actual was folded (unsound)"; fail=1; }
[ "$n_cloopfact" -eq 0 ]              || { echo "  X counted for-loop body not folded"; fail=1; }
[ "$has_5040" -ge 1 ]                 || { echo "  X folded for-loop literal 5040 absent"; fail=1; }
[ -n "$on_out" ] && [ "$on_out" = "$off_out" ] || { echo "  X result mismatch/empty"; fail=1; }
[ "$r_folded" -ge 3 ]                 || { echo "  X missing -OoREPORT folded remarks"; fail=1; }
[ "$r_refuse" -ge 1 ]                 || { echo "  X missing -OoREPORT refusal remark"; fail=1; }

# --- (9) float bit-exactness: a single/double proven-const routine folds and
#         the folded literal is bit-for-bit identical to the SAME routine called
#         at run time (mutable-global args of identical value -> a real call the
#         folder must leave alone). Proves the evaluator rounds every step to the
#         node precision exactly as SSE codegen does (incl. per-step single
#         rounding and the compiler's auto x*x -> sqr). ---
cat > fbit.pas <<'EOF'
program fbit;
{$mode objfpc}{$H+}{$Q-}{$R-}
function schain(a, b: single): single;
var t: single;
begin
  t := a * b + a - b;
  t := t * t - a;          { auto-rewritten to sqr(t): must fold bit-exactly }
  schain := t;
end;
function dchain(a, b: double): double;
var i: longint; s: double;
begin
  s := 0.0;
  for i := 1 to 7 do s := s + a * i - b;
  dchain := s;
end;
var ga: single = 1.1; gb: single = 2.2;
    gda: double = 3.3; gdb: double = 0.7;
    fs, us: single; fd, ud: double;
begin
  fs := schain(1.1, 2.2);        { folded to a literal }
  us := schain(ga, gb);          { runtime call (mutable globals) }
  fd := dchain(3.3, 0.7);        { folded to a literal }
  ud := dchain(gda, gdb);        { runtime call }
  { emit raw IEEE bit patterns: folded==runtime iff bit-exact }
  Writeln(PLongWord(@fs)^, ' ', PLongWord(@us)^, ' ',
          PQWord(@fd)^, ' ', PQWord(@ud)^);
end.
EOF
"$CC" $FLAGS -a -OoREPORT fbit.pas -ofbit >fbit.log 2>&1
fbit_link=$?
# schain/dchain each fold once (the const-arg site) and keep one runtime call
n_fold_schain=$(grep -ciE 'consteval: call to schain folded' fbit.log)
n_fold_dchain=$(grep -ciE 'consteval: call to dchain folded' fbit.log)
n_call_schain=$(grep -ciE 'call[^A-Za-z0-9_]+.*SCHAIN' fbit.s)
n_call_dchain=$(grep -ciE 'call[^A-Za-z0-9_]+.*DCHAIN' fbit.s)
read -r bf_fs bf_us bf_fd bf_ud < <( ( ulimit -v 3000000; timeout 60 ./fbit ) 2>/dev/null )

echo "(9) float bit-exact: single folded=$n_fold_schain runtime-calls=$n_call_schain  folded-bits=$bf_fs runtime-bits=$bf_us"
echo "                     double folded=$n_fold_dchain runtime-calls=$n_call_dchain  folded-bits=$bf_fd runtime-bits=$bf_ud"

[ "$fbit_link" -eq 0 ]                || { echo "  X float bit-exact program failed to link"; cat fbit.log; fail=1; }
[ "$n_fold_schain" -ge 1 ]           || { echo "  X single const call not folded"; fail=1; }
[ "$n_fold_dchain" -ge 1 ]           || { echo "  X double const call not folded"; fail=1; }
[ "$n_call_schain" -eq 1 ]           || { echo "  X single: expected exactly the one runtime call to survive"; fail=1; }
[ "$n_call_dchain" -eq 1 ]           || { echo "  X double: expected exactly the one runtime call to survive"; fail=1; }
[ -n "$bf_fs" ] && [ "$bf_fs" = "$bf_us" ] || { echo "  X single folded literal not bit-identical to runtime"; fail=1; }
[ -n "$bf_fd" ] && [ "$bf_fd" = "$bf_ud" ] || { echo "  X double folded literal not bit-identical to runtime"; fail=1; }

# --- (10) shl/shr masking: a const routine that shifts by a (parameter) count
#          folds, and the folded literal equals the SAME routine at run time even
#          for a >width shift count (x86-64 masks mod 32 / mod 64, so the shift is
#          count-mod-width, never zeroed) and for a signed logical shr. ---
cat > sbit.pas <<'EOF'
program sbit;
{$mode objfpc}{$H+}{$Q-}{$R-}
function shl_l(x: longint; c: longint): longint; begin shl_l := x shl c; end;
function shl_q(x: int64;   c: longint): int64;   begin shl_q := x shl c; end;
function shr_l(x: longint; c: longint): longint; begin shr_l := x shr c; end;
var g1: longint = 1; q1: int64 = 1; gm8: longint = -8;
    c40: longint = 40; c65: longint = 65; c1: longint = 1;
begin
  { folded (const args) then runtime (mutable-global args), same values }
  Writeln(shl_l(1, 40),  ' ', shl_l(g1, c40),
      ' ', shl_q(1, 65),  ' ', shl_q(q1, c65),
      ' ', shr_l(-8, 1),  ' ', shr_l(gm8, c1));
end.
EOF
"$CC" $FLAGS -a -OoREPORT sbit.pas -osbit >sbit.log 2>&1
sbit_link=$?
n_fold_shift=$(grep -ciE 'consteval: call to (shl_l|shl_q|shr_l) folded' sbit.log)
# each of the three helpers keeps exactly its ONE runtime (global-arg) call
n_call_shl_l=$(grep -ciE 'call[^A-Za-z0-9_]+.*SHL_L' sbit.s)
n_call_shl_q=$(grep -ciE 'call[^A-Za-z0-9_]+.*SHL_Q' sbit.s)
n_call_shr_l=$(grep -ciE 'call[^A-Za-z0-9_]+.*SHR_L' sbit.s)
read -r s_fl s_rl s_fq s_rq s_fsr s_rsr < <( ( ulimit -v 3000000; timeout 60 ./sbit ) 2>/dev/null )

echo "(10) shift mask: folded-remarks=$n_fold_shift  runtime-calls(shl_l,shl_q,shr_l)=$n_call_shl_l,$n_call_shl_q,$n_call_shr_l"
echo "     longint 1 shl 40: folded=$s_fl runtime=$s_rl (expect 256)"
echo "     int64   1 shl 65: folded=$s_fq runtime=$s_rq (expect 2)"
echo "     longint -8 shr 1: folded=$s_fsr runtime=$s_rsr (expect 2147483644)"

[ "$sbit_link" -eq 0 ]               || { echo "  X shift program failed to link"; cat sbit.log; fail=1; }
[ "$n_fold_shift" -ge 3 ]            || { echo "  X shift const calls not folded"; fail=1; }
[ "$n_call_shl_l" -eq 1 ]            || { echo "  X shl_l: expected exactly the one runtime call to survive"; fail=1; }
[ "$n_call_shl_q" -eq 1 ]            || { echo "  X shl_q: expected exactly the one runtime call to survive"; fail=1; }
[ "$n_call_shr_l" -eq 1 ]            || { echo "  X shr_l: expected exactly the one runtime call to survive"; fail=1; }
[ "$s_fl" = "$s_rl" ] && [ "$s_fl" = "256" ]        || { echo "  X longint >width shl fold wrong/!=runtime"; fail=1; }
[ "$s_fq" = "$s_rq" ] && [ "$s_fq" = "2" ]          || { echo "  X int64 >width shl fold wrong/!=runtime"; fail=1; }
[ "$s_fsr" = "$s_rsr" ] && [ "$s_fsr" = "2147483644" ] || { echo "  X signed logical shr fold wrong/!=runtime"; fail=1; }

if [ "$fail" -eq 0 ]; then
  echo "PASS: -OoCONSTEVAL folds const calls (scalar, recursive, cross-unit, counted-for, single/double float) to literals bit-exactly; refuses over-budget/non-const/non-constant; sound and byte-identical to baseline"
  exit 0
else
  echo "FAIL: -OoCONSTEVAL"
  exit 1
fi
