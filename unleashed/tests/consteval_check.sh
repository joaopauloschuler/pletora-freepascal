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

var v: longint;
begin
  v := 11;
  Writeln(chelper(20));    { folds -> 41 }
  Writeln(cfact(6));       { folds -> 720 }
  Writeln(addk(6, 7));     { cross-unit fold -> 41 }
  Writeln(cfib(38));       { over budget -> stays a call }
  Writeln(cglob(3));       { not const -> stays a call }
  Writeln(ctripl(v));      { non-constant actual -> stays a call }
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
has_720=$(grep -ciE '\$720\b' main.s)

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
[ -n "$on_out" ] && [ "$on_out" = "$off_out" ] || { echo "  X result mismatch/empty"; fail=1; }
[ "$r_folded" -ge 3 ]                 || { echo "  X missing -OoREPORT folded remarks"; fail=1; }
[ "$r_refuse" -ge 1 ]                 || { echo "  X missing -OoREPORT refusal remark"; fail=1; }

if [ "$fail" -eq 0 ]; then
  echo "PASS: -OoCONSTEVAL folds const calls (scalar, recursive, cross-unit) to literals; refuses over-budget/non-const/non-constant; sound and byte-identical to baseline"
  exit 0
else
  echo "FAIL: -OoCONSTEVAL"
  exit 1
fi
