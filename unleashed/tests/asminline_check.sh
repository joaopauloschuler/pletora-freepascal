#!/usr/bin/env bash
# Codegen + runtime + diagnostic assertions for inlining routines that contain
# an inner `asm ... end` STATEMENT block (FPC Unleashed).
#
# Historically FPC refused to inline ANY routine whose body contained an asm
# block (checknodeinlining set pio_inline_not_possible unconditionally).  We now
# allow it for the sound subset where the asm block references only registers,
# immediates and GLOBAL symbols -- i.e. no operand resolves to a local variable,
# parameter or the function result (a top_local operand / TP-style INLINE
# ait_const).  Local asm labels ARE now supported: each inline copy gets its own
# fresh AB_LOCAL labels (optcall.unique_inline_asm_labels), so a label-branching
# asm block inlined at several call sites no longer collides ("Duplicate label").
# Such a block relocates verbatim into the caller.
#
# This proves:
#   1. a marked-inline procedure whose asm block touches only a global is fully
#      inlined at -O2 (no call to it) and computes the right result at runtime;
#   2. a marked-inline procedure whose asm block defines and branches to a LOCAL
#      label is fully inlined at TWO call sites (no call to it), assembles with
#      no "Duplicate label" error (labels uniqued per site), and runs correctly;
#   3. a routine whose asm block references a parameter/result is NOT inlined and
#      the call-site note states the reason;
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

{ INLINE-SAFE (Task A): asm defines and branches to a local label .Lok.
  Each inline copy gets fresh labels, so inlining at 2+ sites is sound. }
procedure clampzero; inline;
begin
  asm
    cmpl $0, g(%rip)
    jge  .Lok
    movl $0, g(%rip)
  .Lok:
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

var x: longint;
begin
  g := 0;
  incg; incg; incg;          { inlined 3x -> g = 3 }
  g := -5;
  clampzero;                 { inlined: g=-5 < 0 -> clamps to 0 }
  g := 9;
  clampzero;                 { inlined: g=9 >= 0 -> stays 9 }
  x := addasm(3, 4);         { out-of-line -> 7 }
  writeln(g, ' ', x);
end.
EOF

# 1) codegen: incg and clampzero are inlined (no call to them); addasm still called.
"$CC" -Fu"$RTL" -O2 -al -s "$tmp/a.pp" -o"$tmp/abin" >/dev/null 2>&1
incg_calls=$(  grep -cE 'call[[:space:]]+.*_INCG'      "$tmp/a.s" || true)
clamp_calls=$( grep -cE 'call[[:space:]]+.*_CLAMPZERO' "$tmp/a.s" || true)
addasm_calls=$(grep -cE 'call[[:space:]]+.*_ADDASM'    "$tmp/a.s" || true)
# the inlined global op must actually appear in main's body
incg_inlined=$(grep -cE 'incl[[:space:]]+g\(%rip\)'    "$tmp/a.s" || true)
# clampzero's compare must appear at least twice (spliced into both call sites)
clamp_inlined=$(grep -cE 'cmpl[[:space:]]+\$0, ?g\(%rip\)' "$tmp/a.s" || true)
# no local label may be emitted more than once (would fail to assemble)
dup_labels=$(grep -oE '^\.L[A-Za-z0-9_]+:' "$tmp/a.s" | sort | uniq -d | wc -l)

# 2) diagnostics: the call-site "is not inlined" note must name the reason.
notes="$("$CC" -Fu"$RTL" -O2 -vn "$tmp/a.pp" -o"$tmp/abin2" 2>&1 || true)"
addasm_reason=$(printf '%s\n' "$notes" | grep -cF 'is not inlined (assembler block referencing a local variable, parameter or function result)' || true)
# incg and clampzero must NOT trigger any "not inlined" note
incg_note=$(printf '%s\n' "$notes"  | grep -c 'INCG.*not inlined' || true)
clamp_note=$(printf '%s\n' "$notes" | grep -c 'CLAMPZERO.*not inlined' || true)

# 3) runtime correctness (must ASSEMBLE cleanly -- would fail on duplicate label)
"$CC" -Fu"$RTL" -O2 "$tmp/a.pp" -o"$tmp/run" >/dev/null 2>&1
out="$( ulimit -v 3000000; timeout 60 "$tmp/run" )"; runrc=$?

echo "CODEGEN : incg-call=$incg_calls (expect 0) incg-inlined=$incg_inlined (>=1) clamp-call=$clamp_calls (expect 0) clamp-inlined=$clamp_inlined (>=2) dup-labels=$dup_labels (expect 0) addasm-call=$addasm_calls (>=1)"
echo "NOTES   : addasm-reason=$addasm_reason (expect 1) incg-note=$incg_note (expect 0) clamp-note=$clamp_note (expect 0)"
echo "RUNTIME : out='$out' (expect '9 7') rc=$runrc (expect 0)"

rc=0
[ "$incg_calls"    -eq 0 ] || { echo "FAIL: inline-safe asm routine still called (not inlined)"; rc=1; }
[ "$incg_inlined"  -ge 1 ] || { echo "FAIL: inlined global asm op not found in caller body"; rc=1; }
[ "$clamp_calls"   -eq 0 ] || { echo "FAIL: label-branching asm routine still called (not inlined)"; rc=1; }
[ "$clamp_inlined" -ge 2 ] || { echo "FAIL: label-branching asm not spliced into both call sites"; rc=1; }
[ "$dup_labels"    -eq 0 ] || { echo "FAIL: duplicate local asm label emitted (labels not uniqued per site)"; rc=1; }
[ "$addasm_calls"  -ge 1 ] || { echo "FAIL: routine with local-referencing asm was inlined (unsound)"; rc=1; }
[ "$addasm_reason" -eq 1 ] || { echo "FAIL: missing/incorrect reason for local-referencing asm refusal"; rc=1; }
[ "$incg_note"     -eq 0 ] || { echo "FAIL: inline-safe asm routine wrongly reported as not inlined"; rc=1; }
[ "$clamp_note"    -eq 0 ] || { echo "FAIL: label-branching asm routine wrongly reported as not inlined"; rc=1; }
[ "$out" = "9 7" ]         || { echo "FAIL: wrong runtime result '$out'"; rc=1; }
[ "$runrc"         -eq 0 ] || { echo "FAIL: program did not run cleanly (rc=$runrc)"; rc=1; }

[ "$rc" -eq 0 ] && echo "PASS: global-only and label-branching asm blocks inlined (no call, spliced into caller, labels uniqued per site) and correct; local/param-referencing asm block kept out-of-line with an explanatory note; all variants run correctly"
exit "$rc"
