#!/usr/bin/env bash
# Cross-unit inline-asm splicing (FPC Unleashed).
#
# Historically FPC refused to inline ANY asm-block body loaded from another
# unit: the block's tai operands do not survive a ppu round trip in the stock
# compiler -- tcompilerppufile.getasmsymbol returns nil (asm symbols are
# module-local), so a spliced-cross-unit top_ref lost its GLOBAL symbol (null
# store -> SIGSEGV), the operand size was dropped (`mov imm8s,mem32` assembler
# error) and the 2-operand order was re-swapped (FOperandOrder defaulted to
# op_intel while the operands were stored in op_att order).
#
# The lift serializes, for an inline body's asm block:
#   * each top_ref/relsymbol by NAME + bind + typ, re-resolved against the
#     SPLICING unit (a GLOBAL/external symbol becomes an external reference the
#     linker resolves to the defining unit's export);
#   * the x86 taicpu opsize and FOperandOrder (absent from the generic tai_cpu
#     serialization) so the loaded instruction assembles identically.
# A body whose asm references a symbol that CANNOT be reconstructed cross-unit
# (a local asm label, a non-global top_ref, an ait_const sym) is flagged
# asmnf_crossunit_unsafe at ppu-write time and kept out of line.
#
# This script proves, across a unit boundary:
#   (1) the cross-unit call to a SAFE asm routine DISAPPEARS (spliced in);
#   (2) the inlined program runs BIT-EXACTLY identical to the out-of-line
#       (-dNOINL) reference;
#   (3) GLOBAL-symbol references from the spliced block resolve AND link;
#   (4) operand sizes are preserved -- the immediate-to-mem32 store keeps its
#       `movl $42, ...` size suffix (the `mov imm8s,mem32` corruption class);
#   (5) an UNRESOLVABLE body (local asm label) is REFUSED with the precise note
#       and stays out of line -- not miscompiled.
#
# Usage: unleashed/tests/asm_inline_crossunit_check.sh [path-to-ppcx64]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"
FIX="$root/unleashed/tests/testfiles/asm_crossunit"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cp "$FIX/asmcu_lib.pas" "$FIX/asmcu_main.pp" "$tmp/"

build() {  # $1 = extra flags (build dir), $2 = out tag
  local flags="$1" tag="$2"
  local d="$tmp/$tag"; mkdir -p "$d"
  "$CC" -Fu"$RTL" -FE"$d" $flags "$tmp/asmcu_lib.pas" >/dev/null 2>&1
  "$CC" -Fu"$RTL" -Fu"$d" -FE"$d" $flags -al -s "$tmp/asmcu_main.pp" >/dev/null 2>&1
  cp "$d/asmcu_main.s" "$tmp/$tag.s"
  "$CC" -Fu"$RTL" -Fu"$d" -FE"$d" $flags "$tmp/asmcu_main.pp" -oasmcu_$tag >/dev/null 2>&1
}

# --- inlined build (default) and out-of-line reference (-dNOINL) -------------
build "-O4"          inl
build "-O4 -dNOINL"  ref

# (1) the cross-unit calls to the SAFE routines disappear when inlined
inl_addg=$(grep -cE 'call[[:space:]]+.*ADDG'        "$tmp/inl.s" || true)
inl_combo=$(grep -cE 'call[[:space:]]+.*COMBO'      "$tmp/inl.s" || true)
inl_copy=$(grep -cE 'call[[:space:]]+.*COPYGLOBALS' "$tmp/inl.s" || true)
# (5) the UNSAFE (local-label) routine stays out of line even when inlining
inl_clampz=$(grep -cE 'call[[:space:]]+.*CLAMPZ'    "$tmp/inl.s" || true)
# reference build calls every routine out of line
ref_addg=$(grep -cE 'call[[:space:]]+.*ADDG'        "$tmp/ref.s" || true)

# (3) GLOBAL symbol references from the spliced blocks are present + link
inl_gsrc=$(grep -cE 'ASMCU_LIB_\$\$_GSRC' "$tmp/inl.s" || true)
inl_gdst=$(grep -cE 'ASMCU_LIB_\$\$_GDST' "$tmp/inl.s" || true)
# (4) the immediate-to-mem32 store kept its size suffix (`movl $42,<gdst>`)
inl_immsize=$(grep -cE 'movl[[:space:]]+\$42, ?.*GDST' "$tmp/inl.s" || true)
# corruption sentinel: a size-less `mov $imm,<mem>` must NOT appear
inl_badsize=$(grep -cE '^[[:space:]]*mov[[:space:]]+\$[0-9]+, ?.*GDST' "$tmp/inl.s" || true)

# (2) bit-exact runtime equality inlined vs out-of-line
out_inl="$( ulimit -v 3000000; timeout 60 "$tmp/inl/asmcu_inl" )"; rc_inl=$?
out_ref="$( ulimit -v 3000000; timeout 60 "$tmp/ref/asmcu_ref" )"; rc_ref=$?

# (5) the refusal note is precise
note="$("$CC" -Fu"$RTL" -Fu"$tmp/inl" -FE"$tmp/inl" -O4 -vn "$tmp/asmcu_main.pp" 2>&1 || true)"
clampz_note=$(printf '%s\n' "$note" | grep -ciE 'clampz.*not inlined' || true)
safe_note=$(printf '%s\n' "$note" | grep -ciE '(addg|combo|copyglobals).*not inlined' || true)

echo "INLINE  : addg=$inl_addg combo=$inl_combo copyglobals=$inl_copy (all 0, spliced) clampz=$inl_clampz (>=1, out-of-line)"
echo "REF     : addg=$ref_addg (>=1, out-of-line reference)"
echo "GLOBALS : gsrc-refs=$inl_gsrc gdst-refs=$inl_gdst (both >=1, resolve+link)"
echo "OPSIZE  : imm-to-mem32 movl\$42=$inl_immsize (>=1) size-less-bad=$inl_badsize (0)"
echo "RUNTIME : inlined='$out_inl' (rc=$rc_inl) reference='$out_ref' (rc=$rc_ref) -- must match, expect '105 109 42 77 8000'"
echo "NOTES   : clampz-refused=$clampz_note (>=1) safe-wrongly-noted=$safe_note (0)"

rc=0
[ "$inl_addg"   -eq 0 ] || { echo "FAIL: cross-unit addg (global+param) not spliced"; rc=1; }
[ "$inl_combo"  -eq 0 ] || { echo "FAIL: cross-unit combo (imm-to-mem) not spliced"; rc=1; }
[ "$inl_copy"   -eq 0 ] || { echo "FAIL: cross-unit copyglobals (two globals) not spliced"; rc=1; }
[ "$inl_clampz" -ge 1 ] || { echo "FAIL: cross-unit local-label routine was inlined (unsound)"; rc=1; }
[ "$ref_addg"   -ge 1 ] || { echo "FAIL: -dNOINL reference did not stay out of line"; rc=1; }
[ "$inl_gsrc"   -ge 1 ] || { echo "FAIL: spliced block lost the global gsrc reference"; rc=1; }
[ "$inl_gdst"   -ge 1 ] || { echo "FAIL: spliced block lost the global gdst reference"; rc=1; }
[ "$inl_immsize" -ge 1 ] || { echo "FAIL: immediate-to-mem32 store lost its size suffix"; rc=1; }
[ "$inl_badsize" -eq 0 ] || { echo "FAIL: a size-less mov \$imm,mem was emitted (opsize corruption)"; rc=1; }
[ "$out_inl" = "105 109 42 77 8000" ] || { echo "FAIL: inlined runtime result wrong '$out_inl'"; rc=1; }
[ "$out_inl" = "$out_ref" ] || { echo "FAIL: inlined output '$out_inl' != out-of-line reference '$out_ref'"; rc=1; }
[ "$rc_inl" -eq 0 ] || { echo "FAIL: inlined program did not run cleanly (rc=$rc_inl)"; rc=1; }
[ "$rc_ref" -eq 0 ] || { echo "FAIL: reference program did not run cleanly (rc=$rc_ref)"; rc=1; }
[ "$clampz_note" -ge 1 ] || { echo "FAIL: missing refusal note for the local-label body"; rc=1; }
[ "$safe_note"  -eq 0 ] || { echo "FAIL: a spliced safe routine was wrongly reported not inlined"; rc=1; }

[ "$rc" -eq 0 ] && echo "PASS: cross-unit SAFE asm bodies (global refs + value params + immediate-to-mem32) are spliced (no call), link their global symbols, keep operand sizes, and run bit-exactly identical to the out-of-line reference; a local-label body is soundly refused with its note and stays out of line"
exit "$rc"
