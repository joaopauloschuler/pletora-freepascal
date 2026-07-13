#!/usr/bin/env bash
# Assertions for -OoMODREF per-parameter by-reference tracking (tasklist L257
# item (e)).
#
# The mod/ref summary's mr_byref read/write class used to be per-DIRECTION
# coarse: "the routine reads / writes through SOME by-reference parameter",
# mapped at a call site over EVERY by-reference actual.  A call that writes
# through its first var parameter but merely borrows the address of a second
# (never touching it) therefore looked like it wrote through both -- so if the
# second actual was a global, the call was treated as a global writer.
#
# This pass now records a per-formal bitmap of WHICH by-reference parameters the
# routine reads / writes through (bit N = the N-th entry of `paras`), with an
# overflow-to-coarse fallback (mask not exact => every by-ref actual is assumed
# touched, the old behaviour).  A consumer maps only the flagged formals'
# actuals, so an untouched by-ref actual no longer contributes.
#
# Assertions:
#   * -OoREPORT surfaces the correct per-formal masks (writes [params 0] for a
#     param-0-only writer, reads [params 1] for a formal-1-only reader, writes
#     [params 0,1] for a both-writer);
#   * loop store-motion PROMOTES a global `g` across a loop whose body calls a
#     helper that writes only its formal 0 while borrowing global `h` through an
#     untouched var formal 1 -- and only with -OoMODREF;
#   * that same promotion is REFUSED (conservative) when the helper writes BOTH
#     formals (formal 1 == the borrowed global is now genuinely written), proving
#     the win is the per-formal precision, not merely -OoMODREF being on;
#   * the promotion still fires when the helper lives in a SEPARATE unit (the
#     per-formal masks survive ppu serialization);
#   * the promotion is REFUSED for an INDIRECT (procvar) call (no summary).
#
# Usage: unleashed/tests/modref_byref_check.sh [path-to-ppcx64]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ---- per-formal mask REPORT --------------------------------------------------
cat > "$tmp/rep.pp" <<'EOF'
program rep;
{$mode objfpc}
var g, h: longint;
procedure helper(out a: longint; var b: longint); noinline;
begin a := 0; end;
procedure hboth(var a: longint; var b: longint); noinline;
begin a := 0; b := 0; end;
function reader(var b: longint; const c: longint): longint; noinline;
begin reader := c; end;
begin
  helper(g, h); hboth(g, h); writeln(reader(g, 3));
end.
EOF
rep="$("$CC" -Fu"$RTL" -O3 -OoMODREF -OoREPORT "$tmp/rep.pp" -o"$tmp/rep" 2>&1)"

# store-motion kernels ---------------------------------------------------------
mk_sm() { # $1 = helper name/decl file body
  cat > "$tmp/$2" <<EOF
program smt;
{\$mode objfpc}
var g, h: longint; pv: procedure(var x: longint);
$1
function sm(n: longint): longint; noinline;
var i, tmp: longint;
begin
  for i:=1 to n do begin g := g + i; $3; end;
  sm := g + tmp;
end;
begin g:=0; h:=9; pv:=nil; writeln(sm(5)); end.
EOF
}

# param-0-only writer: promotable only with per-formal precision
mk_sm 'procedure helper(out a: longint; var b: longint); noinline;
begin a := 0; end;' sm_only.pp 'helper(tmp, h)'
# both-writer: h genuinely written -> must NOT promote
mk_sm 'procedure hboth(var a: longint; var b: longint); noinline;
begin a := 0; b := 0; end;' sm_both.pp 'hboth(tmp, h)'
# indirect call -> must NOT promote
mk_sm '' sm_ind.pp 'pv(tmp)'

promo() { "$CC" -Fu"$RTL" -O3 $1 -OoSTOREMOTION -OoREPORT "$tmp/$2" -o"$tmp/x" 2>&1 | grep -c 'storemotion: promoted' || true; }

only_mod=$(promo "-OoMODREF" sm_only.pp)
only_base=$(promo "" sm_only.pp)
both_mod=$(promo "-OoMODREF" sm_both.pp)
ind_mod=$(promo "-OoMODREF" sm_ind.pp)

# ---- cross-unit (ppu serialization of the masks) -----------------------------
mkdir -p "$tmp/u"
cat > "$tmp/u/mrh.pas" <<'EOF'
unit mrh;
{$mode objfpc}
interface
procedure helper(out a: longint; var b: longint);
implementation
procedure helper(out a: longint; var b: longint); noinline;
begin a := 0; end;
end.
EOF
cat > "$tmp/u/usemrh.pp" <<'EOF'
program usemrh;
{$mode objfpc}
uses mrh;
var g, h: longint;
function sm(n: longint): longint; noinline;
var i, tmp: longint;
begin
  for i:=1 to n do begin g := g + i; helper(tmp, h); end;
  sm := g + tmp;
end;
begin g:=0; h:=9; writeln(sm(5)); end.
EOF
"$CC" -Fu"$RTL" -O3 -OoMODREF -FE"$tmp/u" "$tmp/u/mrh.pas" >/dev/null 2>&1
xu_mod="$("$CC" -Fu"$RTL" -Fu"$tmp/u" -FU"$tmp/u" -O3 -OoMODREF -OoSTOREMOTION -OoREPORT "$tmp/u/usemrh.pp" -o"$tmp/u/usemrh" 2>&1 | grep -c 'storemotion: promoted' || true)"

echo "REPORT masks:"
echo "$rep" | grep -E 'helper|hboth|reader' | grep modref || true
echo "store motion promotions:"
echo "  param-0-only writer, -OoMODREF=$only_mod (expect >=1), baseline=$only_base (expect 0)"
echo "  both-writer,          -OoMODREF=$both_mod (expect 0, conservative)"
echo "  indirect call,        -OoMODREF=$ind_mod (expect 0, conservative)"
echo "  cross-unit helper,    -OoMODREF=$xu_mod (expect >=1, masks survive ppu)"

rc=0
echo "$rep" | grep -qE "helper\(out LongInt;var LongInt\); mod/ref summary: reads nothing, writes only through by-ref parameters \[params 0\]" \
  || { echo "FAIL: param-0-only writer mask wrong"; rc=1; }
echo "$rep" | grep -qE "hboth\(var LongInt;var LongInt\); mod/ref summary: reads nothing, writes only through by-ref parameters \[params 0,1\]" \
  || { echo "FAIL: both-writer mask wrong"; rc=1; }
echo "$rep" | grep -qE "reader\(var LongInt;const LongInt\):System.LongInt; mod/ref summary: reads only through by-ref parameters \[params 1\]" \
  || { echo "FAIL: formal-1-only reader mask wrong"; rc=1; }
[ "$only_mod" -ge 1 ] || { echo "FAIL: param-0-only writer not promoted under -OoMODREF"; rc=1; }
[ "$only_base" = "0" ] || { echo "FAIL: promoted without -OoMODREF"; rc=1; }
[ "$both_mod" = "0" ] || { echo "FAIL: both-writer wrongly promoted (per-formal precision unsound)"; rc=1; }
[ "$ind_mod" = "0" ] || { echo "FAIL: indirect call wrongly promoted"; rc=1; }
[ "$xu_mod" -ge 1 ] || { echo "FAIL: cross-unit per-formal mask not honored (ppu serialization)"; rc=1; }

[ "$rc" -eq 0 ] && echo "PASS: -OoMODREF per-parameter by-ref tracking refines the summary soundly"
exit "$rc"
