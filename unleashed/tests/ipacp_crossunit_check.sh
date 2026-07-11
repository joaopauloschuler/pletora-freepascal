#!/usr/bin/env bash
# Cross-unit -OoIPACP assertions (follow-up (a): specialize an eligible routine
# defined in a USED unit A from a caller in unit B / the main program).
#
# The clone template is streamed through the SAME vehicle cross-unit inlining
# uses: the eligible callee's pre-firstpass body is retained as inlininginfo
# (WITHOUT po_inline) so it lands in unit A's PPU; a caller unit RECOVERS it from
# the PPU, re-verifies eligibility on the loaded copy, and clones it -- the clone
# emitted into the CALLER's own object as a hidden/local symbol whose mangled
# name carries the caller module's name.  (Cross-unit cloning fires when the
# callee is loaded from a PPU, i.e. true separate compilation -- the standard
# build model of fpmake/lazbuild and the compiler's own `make cycle`; when a unit
# is compiled together with its sources in ONE invocation the callee is the live
# in-memory def and the pass conservatively falls back to the general routine.)
#
# Proves, under -OoIPACP, building bottom-up (ua, then ub, then main):
#   (1) a caller passing a constant to a used unit's routine emits a specialized
#       clone in ITS OWN object, retargets the call, and runs to exactly the same
#       result as the un-optimized build;
#   (2) TWO different units (ub and main) that instantiate the SAME
#       specialization each emit their own HIDDEN, module-qualified clone -- no
#       duplicate-symbol link failure -- and the program links and runs correctly;
#   (3) several call sites in ONE caller module passing the same constant share
#       ONE clone (per-module cache);
#   (4) nothing clones cross-unit when the switch is off.
#
# Usage: unleashed/tests/ipacp_crossunit_check.sh [path-to-ppcx64]
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

# Shared used unit A: an EXPORTED routine with a constant-foldable loop bound +
# branch, plus a unit-PRIVATE helper it calls (exercises the export_local_ref
# path so the clone's reference to A's private symbol links).
cat > ua.pas <<'EOF'
unit ua;
{$mode objfpc}{$H+}
interface
function poly(x: longint; n: longint): longint;
implementation
const BIAS = 100;
function helper(v: longint): longint; begin helper := v + BIAS; end;
function poly(x: longint; n: longint): longint;
var i, r: longint;
begin
  r := 0;
  if n <= 0 then exit(0);
  for i := 1 to n do r := r * x + i;
  poly := helper(r);
end;
end.
EOF

# Caller unit B: two call sites passing the SAME spec poly(2,3) (per-module reuse
# -> one clone) -- and poly(2,3) is ALSO used by main (duplicate spec, other module).
cat > ub.pas <<'EOF'
unit ub;
{$mode objfpc}{$H+}
interface
uses ua;
function bcalc: longint;
implementation
function bcalc: longint;
begin
  bcalc := poly(2, 3) + poly(2, 3);
end;
end.
EOF

# Main program: uses poly(2,3) (dup spec) and poly(3,3) (distinct spec).
cat > main.pas <<'EOF'
program main;
{$mode objfpc}{$H+}
uses ua, ub;
begin
  Writeln(poly(2, 3) + poly(3, 3) + bcalc);
end.
EOF

clone_defs() { grep -oiE '^[A-Za-z0-9_$]*\$ipacp\$[A-Za-z0-9_$]+:' "$1" 2>/dev/null | sed 's/:$//' | sort -u; }
cnt() { clone_defs "$1" | grep -c . ; }

# --- ON build, bottom-up separate compilation; -a keeps the generated .s AND
#     still assembles+links, so we get both the object symbols and a binary ---
"$CC" -Fu"$RTL"            -O2 -OoIPACP -a ua.pas               >ua.log   2>&1
"$CC" -Fu"$RTL" -Fu. -FU.  -O2 -OoIPACP -a ub.pas              >ub.log   2>&1
"$CC" -Fu"$RTL" -Fu. -FU.  -O2 -OoIPACP -a main.pas -omain_on  >link_on.log 2>&1
link_ok=$?

ub_defs=$(cnt ub.s)
main_defs=$(cnt main.s)
ub_hidden=$(grep -ciE '\.hidden.*\$ipacp\$' ub.s)
main_hidden=$(grep -ciE '\.hidden.*\$ipacp\$' main.s)
ub_qual=$(clone_defs ub.s | grep -ic '\$ipacp\$ub\$')
main_qual=$(clone_defs main.s | grep -ic '\$ipacp\$main\$')
on_out=$( ( ulimit -v 3000000; timeout 60 ./main_on ) 2>/dev/null )

# --- OFF build (baseline reference; no clones anywhere) ---
rm -f ./*.o ./*.ppu ./*.s
"$CC" -Fu"$RTL"           -O2 -a ua.pas               >/dev/null 2>&1
"$CC" -Fu"$RTL" -Fu. -FU. -O2 -a ub.pas               >/dev/null 2>&1
"$CC" -Fu"$RTL" -Fu. -FU. -O2 -a main.pas -omain_off  >/dev/null 2>&1
off_clones=$(grep -rilE '\$ipacp\$' ./*.s 2>/dev/null | grep -c . )
off_out=$( ( ulimit -v 3000000; timeout 60 ./main_off ) 2>/dev/null )

echo "(1) cross-unit run: on=$on_out off=$off_out  link_on_rc=$link_ok (must match, rc 0)"
echo "(2) two-caller same-spec: ub clone defs=$ub_defs  main clone defs=$main_defs  hidden(ub=$ub_hidden,main=$main_hidden)"
echo "    module-qualified: ub-\$ipacp\$ub\$=$ub_qual  main-\$ipacp\$main\$=$main_qual"
echo "(3) per-module reuse: ub has $ub_defs clone(s) for its 2 same-spec sites (expect 1)"
echo "(4) switch-off clones: $off_clones (expect 0)"

fail=0
[ "$link_ok" -eq 0 ]             || { echo "  X ON link failed (duplicate symbol?)"; cat link_on.log; fail=1; }
[ -n "$on_out" ] && [ "$on_out" = "$off_out" ] || { echo "  X result mismatch/empty"; fail=1; }
[ "$ub_defs" -eq 1 ]             || { echo "  X ub must emit exactly one shared clone"; fail=1; }
[ "$main_defs" -eq 2 ]           || { echo "  X main must emit two clones (2,3 and 3,3)"; fail=1; }
[ "$ub_hidden" -ge 1 ]           || { echo "  X ub clone not hidden/local"; fail=1; }
[ "$main_hidden" -ge 2 ]         || { echo "  X main clones not hidden/local"; fail=1; }
[ "$ub_qual" -ge 1 ]             || { echo "  X ub clone name not module-qualified"; fail=1; }
[ "$main_qual" -ge 2 ]           || { echo "  X main clone names not module-qualified"; fail=1; }
[ "$off_clones" -eq 0 ]          || { echo "  X clones emitted with switch off"; fail=1; }

if [ "$fail" -eq 0 ]; then
  echo "PASS: cross-unit clones (per-caller-module, hidden, module-qualified, shared per module, sound, link-clean across two units instantiating the same spec)"
  exit 0
else
  echo "FAIL: cross-unit IPACP"
  exit 1
fi
