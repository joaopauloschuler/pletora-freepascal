#!/usr/bin/env bash
# -OoICF zero-byte symbol-alias fold vs debug info (regression for IE 200404124).
#
# The alias fold relocates a duplicate routine's entry symbol OUT of its own
# per-function .text.n_<dup> section and into the survivor's .text.n_<rep>
# section (a second label at the survivor's address, zero bytes).  Under
# section-per-function (the default) dup and rep are always in distinct
# sections, so with debug info this strands the duplicate's own end/line labels:
# the per-proc DWARF address range and .debug_aranges entry emitted for the
# duplicate (low_pc = its symbol, length = <its-end-label> - <its-symbol>) then
# straddle two sections and the internal assembler raises IE 200404124 (found by
# fantastica/fpc-torture seeds 3 & 11: an -OoIPACP clone whose debug range is
# emitted during the clone's own compilation, before ICF, then alias-folded).
#
# Fix: whenever per-proc debug ranges are generated, ICF must fall back to the
# jmp-thunk fold (which keeps the duplicate's symbol, end-label and section
# header together, so its debug range stays intra-section and valid).
#
# This script asserts, on an address-never-taken byte-identical duplicate:
#   (1) no debug info  -> zero-byte alias (duplicate label at survivor address);
#   (2) -gh (debug)    -> jmp thunk, NOT an alias  [the fix];
#   (3) both build+run clean with identical results (the -gh build no longer ICEs).
#
# Usage: unleashed/tests/icf_debug_check.sh [path-to-ppcx64]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
rc=0

cat > alib.pas <<'EOF'
unit alib;
{$mode objfpc}
interface
function Compute(a,b,c,d: longint): longint;
implementation
{ Foo and Bar are byte-identical and neither address is ever taken as a value,
  so ICF treats Bar as a zero-byte-alias candidate (falls back to a thunk under
  debug info). }
function Foo(a,b,c,d: longint): longint; noinline;
begin
  result:=a*b+c-d; result:=result*a; result:=result xor b;
  result:=result+c*d; result:=result-a*c; result:=result or d;
  result:=result*3+7; result:=result and $7f; result:=result shl 2;
end;
function Bar(a,b,c,d: longint): longint; noinline;
begin
  result:=a*b+c-d; result:=result*a; result:=result xor b;
  result:=result+c*d; result:=result-a*c; result:=result or d;
  result:=result*3+7; result:=result and $7f; result:=result shl 2;
end;
function Compute(a,b,c,d: longint): longint;
begin result:=Foo(a,b,c,d)+Bar(d,c,b,a); end;
end.
EOF

cat > amain.pp <<'EOF'
program amain;
{$mode objfpc}
uses alib;
begin
  writeln(Compute(3,5,7,9));
end.
EOF

symname(){ grep -oE "ALIB_\\\$\\\$_$1\\\$[A-Z\$]*" "$2" | head -1; }
# Bar's own label emitted right after Foo's label with no instruction between => alias
is_alias_after(){ awk -v a="$1:" -v b="$2:" '
  $0==a{seen=1;next}
  seen{ if($0==b){print "YES";exit} if($0 ~ /^\t[a-z]/){exit} }' "$3"; }
jmp_to(){ awk -v n="$1" '$1=="jmp" && $2==n{f=1} END{exit !f}' "$2"; }

echo "== (1) no debug info: zero-byte alias =="
"$CC" -Fu"$RTL" -O2 -OoICF -a -s alib.pas >/dev/null 2>&1
foo=$(symname FOO alib.s); bar=$(symname BAR alib.s)
if [ "$(is_alias_after "$foo" "$bar" alib.s)" = YES ]; then
  echo "  Bar aliased at Foo's address (zero-byte fold)"
else echo "  FAIL: Bar not aliased onto Foo without debug info"; rc=1; fi
if jmp_to "$foo" alib.s; then echo "  FAIL: unexpected jmp thunk without debug info"; rc=1; fi

echo "== (2) -gh (debug): jmp thunk, not alias  [fix] =="
"$CC" -Fu"$RTL" -O2 -OoICF -gh -a -s alib.pas >/dev/null 2>&1
foo=$(symname FOO alib.s); bar=$(symname BAR alib.s)
if jmp_to "$foo" alib.s; then echo "  Bar folded to a jmp thunk to Foo"; else
  echo "  FAIL: Bar did not thunk-fold under debug info"; rc=1; fi
if [ "$(is_alias_after "$foo" "$bar" alib.s)" = YES ]; then
  echo "  FAIL: Bar aliased across sections under debug info (would IE 200404124)"; rc=1
else echo "  Bar not aliased under debug info (no cross-section debug range)"; fi

echo "== (3) build+run clean and bit-identical (no ICE) =="
declare -a out
i=0
for cfg in "off:-O2" "alias:-O2 -OoICF" "thunkdbg:-O2 -OoICF -gh"; do
  tag="${cfg%%:*}"; opt="${cfg##*:}"
  if ! "$CC" -Fu"$RTL" $opt alib.pas >/dev/null 2>&1; then echo "  FAIL: compile alib ($tag)"; rc=1; fi
  if ! "$CC" -Fu"$RTL" -Fu. $opt amain.pp -o"amain_$tag" >/dev/null 2>&1; then echo "  FAIL: compile/link amain ($tag) [ICE?]"; rc=1; fi
  o="$( ( ulimit -v 3000000; timeout 30 "./amain_$tag" 2>/dev/null ) )"; e=$?
  echo "  [$tag] out='$o' exit=$e"
  [ "$e" -eq 0 ] || { echo "  FAIL: nonzero exit ($tag)"; rc=1; }
  out[$i]="$o"; i=$((i+1))
done
for j in 1 2; do
  [ "${out[$j]}" = "${out[0]}" ] || { echo "  FAIL: output not bit-identical ($j vs 0)"; rc=1; }
done

[ "$rc" -eq 0 ] && echo "PASS: -OoICF alias fold falls back to thunk under debug info (IE 200404124 fixed)"
exit $rc
