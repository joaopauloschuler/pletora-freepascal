#!/usr/bin/env bash
# Codegen + runtime + diagnostic assertions for inlining routines that contain
# an inner `asm ... end` STATEMENT block (FPC Unleashed).
#
# Historically FPC refused to inline ANY routine whose body contained an asm
# block (checknodeinlining set pio_inline_not_possible unconditionally).  The
# landed subset now inlines such routines for a growing set of cases:
#
#   * global-only blocks (registers/immediates/GLOBAL symbols) relocate verbatim;
#   * local asm labels are uniqued per inline site (Task A,
#     optcall.unique_inline_asm_labels) so a label-branching block inlined at
#     several call sites no longer collides ("Duplicate label");
#   * top_local operands referencing a VALUE PARAMETER, a plain LOCAL or the
#     ordinal/pointer FUNCTION RESULT are handled (Task B,
#     optcall.expand_inline_asm_operands): each referenced callee sym is
#     materialised as a real localvarsym in the caller frame, the argument is
#     copied in, and the operand is rebound;
#   * BY-REFERENCE parameters (var / out / const-ref) of any non-managed type
#     are handled too: the operand resolves to the hidden pointer slot, so a
#     caller pointer local is initialised to @actual and the operand rebound,
#     relocating only the address -- the spliced asm reads AND writes the
#     caller's actual, exactly as out-of-line.  ALL of these are SAME-UNIT only.
#
# Still refused (with a precise call-site note):
#   * MANAGED operands (any passing convention) and BY-VALUE aggregate
#     parameters/locals; TP-style INLINE() placeholders.
#
# CROSS-UNIT: an asm-block body loaded from another unit now inlines too when
# all its operands round-trip through the ppu soundly -- registers, constants,
# top_local params/locals/result and GLOBAL top_ref symbols (re-resolved by name
# against the splicing unit).  The tai serialization was extended to record the
# operand size (opsize), the 2-operand order (FOperandOrder) and every top_ref/
# relsymbol by name+bind+typ (see asm_inline_crossunit_check.sh).  A body whose
# asm references a symbol that CANNOT be reconstructed cross-unit (a local asm
# label, a non-global top_ref, an ait_const sym) is flagged cross-unit-unsafe at
# ppu-write time and kept out of line (runs correctly).
#
# This proves each direction inlines-or-refuses as intended AND runs correctly.
#
# Usage: unleashed/tests/asminline_check.sh [path-to-ppcx64]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ---------------------------------------------------------------------------
# Part 1: same-unit program exercising every inlinable/refused kind.
# ---------------------------------------------------------------------------
cat > "$tmp/a.pp" <<'EOF'
{$mode objfpc}
program a;
type tr = record a, b: longint; end;
var g: longint;

{ INLINE-SAFE: asm touches only the global g and registers }
procedure incg; inline;
begin
  asm
    incl g(%rip)
  end;
end;

{ INLINE-SAFE (Task A): defines and branches to a local label .Lok }
procedure clampzero; inline;
begin
  asm
    cmpl $0, g(%rip)
    jge  .Lok
    movl $0, g(%rip)
  .Lok:
  end;
end;

{ INLINE-SAFE (Task B): value params + ordinal result via top_local operands }
function addasm(a, b: longint): longint; inline;
begin
  asm
    movl a, %eax
    addl b, %eax
    movl %eax, result
  end;
end;

{ INLINE-SAFE (Task B): value params + a plain LOCAL + result }
function madd(a, b: longint): longint; inline;
var t: longint;
begin
  asm
    movl a, %eax
    imull b, %eax
    movl %eax, t
    addl a, %eax
    movl %eax, result
  end;
  if t = 0 then ;
end;

{ INLINE-SAFE (by-ref): a var parameter read AND written through the inline }
procedure incby(var x: longint; d: longint); inline;
begin
  asm
    movq x, %rdx
    movl d, %eax
    addl %eax, (%rdx)
  end;
end;

{ INLINE-SAFE (by-ref): an out parameter written through the inline }
procedure setout(out y: longint); inline;
begin
  asm
    movq y, %rcx
    movl $99, (%rcx)
  end;
end;

{ INLINE-SAFE (by-ref aggregate): a const-ref record field read }
function firstb(constref r: tr): longint; inline;
begin
  asm
    movq r, %rsi
    movl 4(%rsi), %eax
    movl %eax, result
  end;
end;

{ REFUSED: managed by-reference operand (ansistring) }
procedure touchstr(var s: ansistring); inline;
begin
  asm
    movq s, %rax
  end;
end;

var r, s, u, w, z, o, k: longint; rr: tr; ss: ansistring;
begin
  g := 0;
  incg; incg; incg;          { inlined 3x -> g = 3 }
  g := -5; clampzero;        { inlined: -5 -> 0 }
  g := 9;  clampzero;        { inlined: 9 stays 9 }
  r := addasm(3, 4);         { inlined -> 7 }
  s := addasm(100, 23);      { inlined -> 123 }
  u := madd(3, 4);           { inlined -> 3*4+3 = 15 }
  w := madd(10, 5);          { inlined -> 10*5+10 = 60 }
  z := 1; incby(z, 41);      { inlined -> 42 }
  incby(z, 100);             { inlined -> 142 (read+write proof) }
  setout(o);                 { inlined -> 99 }
  rr.a := 5; rr.b := 88;
  k := firstb(rr);           { inlined -> 88 }
  ss := 'x'; touchstr(ss);   { out-of-line (managed, refused) }
  writeln(g, ' ', r, ' ', s, ' ', u, ' ', w, ' ', z, ' ', o, ' ', k, ' ', ss);
end.
EOF

"$CC" -Fu"$RTL" -O2 -al -s "$tmp/a.pp" -o"$tmp/abin" >/dev/null 2>&1
incg_calls=$(  grep -cE 'call[[:space:]]+.*_INCG'      "$tmp/a.s" || true)
clamp_calls=$( grep -cE 'call[[:space:]]+.*_CLAMPZERO' "$tmp/a.s" || true)
addasm_calls=$(grep -cE 'call[[:space:]]+.*_ADDASM'    "$tmp/a.s" || true)
madd_calls=$(  grep -cE 'call[[:space:]]+.*_MADD'      "$tmp/a.s" || true)
incby_calls=$( grep -cE 'call[[:space:]]+.*_INCBY'     "$tmp/a.s" || true)
setout_calls=$(grep -cE 'call[[:space:]]+.*_SETOUT'    "$tmp/a.s" || true)
firstb_calls=$(grep -cE 'call[[:space:]]+.*_FIRSTB'    "$tmp/a.s" || true)
touchstr_calls=$(grep -cE 'call[[:space:]]+.*_TOUCHSTR' "$tmp/a.s" || true)
# spliced-body evidence
incg_inlined=$(grep -cE 'incl[[:space:]]+g\(%rip\)'    "$tmp/a.s" || true)
clamp_inlined=$(grep -cE 'cmpl[[:space:]]+\$0, ?g\(%rip\)' "$tmp/a.s" || true)
dup_labels=$(grep -oE '^\.L[A-Za-z0-9_]+:' "$tmp/a.s" | sort | uniq -d | wc -l)

# diagnostics
notes="$("$CC" -Fu"$RTL" -O2 -vn "$tmp/a.pp" -o"$tmp/abin2" 2>&1 || true)"
touchstr_reason=$(printf '%s\n' "$notes" | grep -cF 'is not inlined (assembler block referencing a managed operand or a by-value aggregate parameter/local)' || true)
inlined_notes=$(printf '%s\n' "$notes" | grep -cE '(INCG|CLAMPZERO|ADDASM|MADD|INCBY|SETOUT|FIRSTB).*not inlined' || true)

# runtime (must assemble cleanly and compute correctly, incl. -O4 -Sew clean)
"$CC" -Fu"$RTL" -O4 -Sew "$tmp/a.pp" -o"$tmp/run" >/dev/null 2>&1
out="$( ulimit -v 3000000; timeout 60 "$tmp/run" )"; runrc=$?

# ---------------------------------------------------------------------------
# Part 2: cross-unit.  A SAFE asm-block body (value params + result AND a
# global-only block) now INLINES across units -- the tai serialization records
# operand size/order and re-resolves the GLOBAL top_ref symbol by name.  An
# UNSAFE body (a local asm label, unreconstructable cross-unit) stays out of
# line.  Both run correctly.  (Full cross-unit coverage: asm_inline_crossunit_
# check.sh.)
# ---------------------------------------------------------------------------
cat > "$tmp/uax.pas" <<'EOF'
{$mode objfpc}
unit uax;
interface
var srcg, dstg: longint;
function addasm(a, b: longint): longint; inline;
procedure cpy; inline;
function clampz(x: longint): longint; inline;
implementation
function addasm(a, b: longint): longint; inline;
begin
  asm
    movl a, %eax
    addl b, %eax
    movl %eax, result
  end;
end;
procedure cpy; inline;
begin
  asm
    movl srcg(%rip), %eax
    movl %eax, dstg(%rip)
  end;
end;
{ UNSAFE cross-unit: an AB_LOCAL asm label cannot be reconstructed in another
  unit, so this body is flagged cross-unit-unsafe and stays out of line. }
function clampz(x: longint): longint; inline;
begin
  asm
    movl x, %eax
    cmpl $0, %eax
    jge .Lok
    xorl %eax, %eax
  .Lok:
    movl %eax, result
  end;
end;
end.
EOF
cat > "$tmp/mx.pas" <<'EOF'
{$mode objfpc}
program mx;
uses uax;
begin
  srcg := 77; dstg := 0;
  cpy;
  writeln(addasm(30, 12), ' ', dstg, ' ', clampz(-3), ' ', clampz(9));
end.
EOF
"$CC" -Fu"$RTL" -O4 -FE"$tmp" "$tmp/uax.pas" >/dev/null 2>&1
"$CC" -Fu"$RTL" -Fu"$tmp" -FE"$tmp" -O4 -al -s "$tmp/mx.pas" >/dev/null 2>&1
xu_calls=$(grep -cE 'call[[:space:]]+.*ADDASM' "$tmp/mx.s" || true)
xu_cpy_calls=$(grep -cE 'call[[:space:]]+.*CPY' "$tmp/mx.s" || true)
xu_clampz_calls=$(grep -cE 'call[[:space:]]+.*CLAMPZ' "$tmp/mx.s" || true)
"$CC" -Fu"$RTL" -Fu"$tmp" -FE"$tmp" -O4 "$tmp/mx.pas" -o"$tmp/mxrun" >/dev/null 2>&1
xu_out="$( ulimit -v 3000000; timeout 60 "$tmp/mxrun" )"; xu_rc=$?

echo "CODEGEN : incg=$incg_calls clamp=$clamp_calls addasm=$addasm_calls madd=$madd_calls incby=$incby_calls setout=$setout_calls firstb=$firstb_calls (all expect 0) touchstr=$touchstr_calls (>=1)"
echo "        : incg-inlined=$incg_inlined (>=1) clamp-inlined=$clamp_inlined (>=2) dup-labels=$dup_labels (0)"
echo "NOTES   : touchstr-reason=$touchstr_reason (expect 1) inlined-wrongly-noted=$inlined_notes (expect 0)"
echo "RUNTIME : out='$out' (expect '9 7 123 15 60 142 99 88 x') rc=$runrc (0)"
echo "CROSSUNIT: addasm-call=$xu_calls cpy-call=$xu_cpy_calls (0, inlined) clampz-call=$xu_clampz_calls (>=1, out-of-line) out='$xu_out' (expect '42 77 0 9') rc=$xu_rc (0)"

rc=0
[ "$incg_calls"   -eq 0 ] || { echo "FAIL: incg not inlined"; rc=1; }
[ "$clamp_calls"  -eq 0 ] || { echo "FAIL: clampzero not inlined"; rc=1; }
[ "$addasm_calls" -eq 0 ] || { echo "FAIL: addasm (value params + result) not inlined"; rc=1; }
[ "$madd_calls"   -eq 0 ] || { echo "FAIL: madd (params + local + result) not inlined"; rc=1; }
[ "$incby_calls"  -eq 0 ] || { echo "FAIL: incby (var by-ref param) not inlined"; rc=1; }
[ "$setout_calls" -eq 0 ] || { echo "FAIL: setout (out by-ref param) not inlined"; rc=1; }
[ "$firstb_calls" -eq 0 ] || { echo "FAIL: firstb (constref aggregate by-ref) not inlined"; rc=1; }
[ "$touchstr_calls" -ge 1 ] || { echo "FAIL: managed-operand asm routine was inlined (unsound)"; rc=1; }
[ "$incg_inlined" -ge 1 ] || { echo "FAIL: inlined global asm op not found in caller"; rc=1; }
[ "$clamp_inlined" -ge 2 ] || { echo "FAIL: label-branching asm not spliced into both sites"; rc=1; }
[ "$dup_labels"   -eq 0 ] || { echo "FAIL: duplicate local asm label emitted"; rc=1; }
[ "$touchstr_reason" -eq 1 ] || { echo "FAIL: missing/incorrect reason for managed-operand asm refusal"; rc=1; }
[ "$inlined_notes" -eq 0 ] || { echo "FAIL: an inlined asm routine wrongly reported as not inlined"; rc=1; }
[ "$out" = "9 7 123 15 60 142 99 88 x" ] || { echo "FAIL: wrong runtime result '$out'"; rc=1; }
[ "$runrc"        -eq 0 ] || { echo "FAIL: program did not run cleanly (rc=$runrc)"; rc=1; }
[ "$xu_calls"     -eq 0 ] || { echo "FAIL: cross-unit value-param asm routine was NOT inlined"; rc=1; }
[ "$xu_cpy_calls" -eq 0 ] || { echo "FAIL: cross-unit global-only asm routine was NOT inlined"; rc=1; }
[ "$xu_clampz_calls" -ge 1 ] || { echo "FAIL: cross-unit local-label asm routine was inlined (unsound)"; rc=1; }
[ "$xu_out" = "42 77 0 9" ] || { echo "FAIL: cross-unit result wrong '$xu_out'"; rc=1; }
[ "$xu_rc"        -eq 0 ] || { echo "FAIL: cross-unit program did not run cleanly (rc=$xu_rc)"; rc=1; }

[ "$rc" -eq 0 ] && echo "PASS: global-only, label-branching, value-param/local/result AND by-reference (var/out/constref) asm blocks inline same-unit (no call, correct, labels uniqued, no dup, read+write through the site); managed operand stays out-of-line with its note; cross-unit SAFE asm bodies (value-param AND global-only) now inline and run bit-exact, while a local-label body stays out-of-line and correct; all variants run (incl -O4 -Sew)"
exit "$rc"
