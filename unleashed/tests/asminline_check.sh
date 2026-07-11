#!/usr/bin/env bash
# Codegen + runtime + diagnostic assertions for inlining routines that contain
# an inner `asm ... end` STATEMENT block (FPC Unleashed).
#
# Historically FPC refused to inline ANY routine whose body contained an asm
# block (checknodeinlining set pio_inline_not_possible unconditionally).  We now
# allow it for the sound subset where the asm block references only registers,
# immediates and GLOBAL symbols -- i.e. no operand resolves to a local variable,
# parameter or the function result (a top_local operand / TP-style INLINE
# ait_const), and the block defines no local asm label (labels are not yet
# uniqued per inline site).  Such a block relocates verbatim into the caller.
#
# This proves:
#   1. a marked-inline procedure whose asm block touches only a global is fully
#      inlined at -O2 (no call to it) and computes the right result at runtime;
#   2. a routine whose asm block references a parameter/result is NOT inlined and
#      the call-site note states the reason;
#   3. a routine whose asm block defines a label is NOT inlined and the call-site
#      note states the reason;
#   4. every case still compiles and runs correctly (refused ones out-of-line).
#
# Usage: unleashed/tests/asminline_check.sh [path-to-ppcx64]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/a.pp" <<'EOF'
{$mode objfpc}
program a;
var g: longint;

{ INLINE-SAFE: asm touches only the global g and registers -> inlinable }
procedure incg; inline;
begin
  asm
    incl g(%rip)
  end;
end;

{ REFUSED: asm references parameter a and the function result (top_local) }
function addasm(a, b: longint): longint; inline;
begin
  asm
    movl a, %eax
    addl b, %eax
    movl %eax, result
  end;
end;

{ REFUSED: asm defines a local label (.Lok) -> not uniqued per inline site }
procedure clampzero; inline;
begin
  asm
    cmpl $0, g(%rip)
    jge  .Lok
    movl $0, g(%rip)
  .Lok:
  end;
end;

var x: longint;
begin
  g := 0;
  incg; incg; incg;          { inlined 3x -> g = 3 }
  x := addasm(3, 4);         { out-of-line -> 7 }
  clampzero;                 { out-of-line: g=3 >= 0 stays 3 }
  writeln(g, ' ', x);
end.
EOF

# 1) codegen: incg is inlined (no call to it), addasm/clampzero are still called.
"$CC" -Fu"$RTL" -O2 -al -s "$tmp/a.pp" -o"$tmp/abin" >/dev/null 2>&1
incg_calls=$(  grep -cE 'call[[:space:]]+.*_INCG'      "$tmp/a.s" || true)
addasm_calls=$(grep -cE 'call[[:space:]]+.*_ADDASM'    "$tmp/a.s" || true)
clamp_calls=$( grep -cE 'call[[:space:]]+.*_CLAMPZERO' "$tmp/a.s" || true)
# the inlined global op must actually appear in main's body
incg_inlined=$(grep -cE 'incl[[:space:]]+g\(%rip\)'    "$tmp/a.s" || true)

# 2) diagnostics: the call-site "is not inlined" note must name the reason.
notes="$("$CC" -Fu"$RTL" -O2 -vn "$tmp/a.pp" -o"$tmp/abin2" 2>&1 || true)"
addasm_reason=$(printf '%s\n' "$notes" | grep -cF 'is not inlined (assembler block referencing a local variable, parameter or function result)' || true)
clamp_reason=$( printf '%s\n' "$notes" | grep -cF 'is not inlined (assembler block defining a label)' || true)
# incg must NOT trigger any "not inlined" note
incg_note=$(printf '%s\n' "$notes" | grep -c 'INCG.*not inlined' || true)

# 3) runtime correctness
"$CC" -Fu"$RTL" -O2 "$tmp/a.pp" -o"$tmp/run" >/dev/null 2>&1
out="$( ulimit -v 3000000; timeout 60 "$tmp/run" )"; runrc=$?

echo "CODEGEN : incg-call=$incg_calls (expect 0) incg-inlined=$incg_inlined (>=1) addasm-call=$addasm_calls (>=1) clamp-call=$clamp_calls (>=1)"
echo "NOTES   : addasm-reason=$addasm_reason (expect 1) clamp-reason=$clamp_reason (expect 1) incg-note=$incg_note (expect 0)"
echo "RUNTIME : out='$out' (expect '3 7') rc=$runrc (expect 0)"

rc=0
[ "$incg_calls"    -eq 0 ] || { echo "FAIL: inline-safe asm routine still called (not inlined)"; rc=1; }
[ "$incg_inlined"  -ge 1 ] || { echo "FAIL: inlined global asm op not found in caller body"; rc=1; }
[ "$addasm_calls"  -ge 1 ] || { echo "FAIL: routine with local-referencing asm was inlined (unsound)"; rc=1; }
[ "$clamp_calls"   -ge 1 ] || { echo "FAIL: routine with labelled asm was inlined (unsound)"; rc=1; }
[ "$addasm_reason" -eq 1 ] || { echo "FAIL: missing/incorrect reason for local-referencing asm refusal"; rc=1; }
[ "$clamp_reason"  -eq 1 ] || { echo "FAIL: missing/incorrect reason for labelled asm refusal"; rc=1; }
[ "$incg_note"     -eq 0 ] || { echo "FAIL: inline-safe asm routine wrongly reported as not inlined"; rc=1; }
[ "$out" = "3 7" ]         || { echo "FAIL: wrong runtime result '$out'"; rc=1; }
[ "$runrc"         -eq 0 ] || { echo "FAIL: program did not run cleanly (rc=$runrc)"; rc=1; }

[ "$rc" -eq 0 ] && echo "PASS: global-only asm block inlined (no call, spliced into caller) and correct; local/param- and label-referencing asm blocks kept out-of-line with an explanatory note; all variants run correctly"
exit "$rc"
