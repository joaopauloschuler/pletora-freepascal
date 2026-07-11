#!/usr/bin/env bash
# Assertions for -OoMODREF per-location (per-static-variable) aliasing precision
# (tasklist L256 item (d)).
#
# The mod/ref summary's mr_unknown ("touches arbitrary global/static/heap
# memory") read/write class used to be per-DIRECTION coarse: any global access
# collapsed to "reads/writes SOME global", so a consumer had to treat a call as
# a reader/writer of EVERY globally-reachable location.  A helper that writes
# only static B therefore blocked promoting an unrelated global A across a loop
# in its caller (and kept every global pending dead-store live in DSE).
#
# The producer now records, per routine, the bounded SET of statics it reads /
# writes -- each identified by its (globally-unique, linker-stable) MANGLED NAME
# so the identity is sound cross-unit -- plus an smask_exact bit that clears (and
# reverts mr_unknown to the coarse "any global") on any unattributable global /
# heap access or on set overflow (>8).  Two consumers were taught the refinement:
#
#   * loop STORE MOTION (compiler/optloop.pas, sm_call_transparent): a body call
#     may stay inside a loop that promotes global A iff it provably neither reads
#     nor writes A -- touching only an unrelated static B is harmless because B
#     keeps its normal in-memory semantics;
#   * dead-store elimination (compiler/optdeadstore.pas, invalidate_globals): a
#     pending store to static A survives a call whose exact read/write footprint
#     provably excludes A.
#
# Assertions:
#   * -OoREPORT surfaces the per-static write set (writes ... [statics <mangled>]);
#   * store motion PROMOTES global g across a loop whose body calls a helper that
#     writes only the unrelated static h -- and only with -OoMODREF;
#   * that promotion is REFUSED when the helper writes the PROMOTED global g
#     (the writer genuinely invalidates it), for an INDIRECT (procvar) call, and
#     for an OVERFLOWING helper that writes >8 statics (smask not exact);
#   * the promotion still fires when the disjoint helper lives in a SEPARATE unit
#     (the static set survives ppu serialization) and is still REFUSED for a
#     cross-unit helper that writes the promoted (same, cross-unit) static;
#   * the SAME-SOURCE-NAMED static in another unit is a DISTINCT location (a
#     distinct mangled name): a helper writing another unit's `g` does NOT block
#     promoting the caller's own `g` -- soundly, since they are different memory;
#   * DSE removes a dead store to a main-scope static across a call that writes
#     only a disjoint static -- only with -OoMODREF.
#
# Usage: unleashed/tests/modref_static_check.sh [path-to-ppcx64]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ---- per-static REPORT --------------------------------------------------------
cat > "$tmp/rep.pp" <<'EOF'
program rep;
{$mode objfpc}
var a, b: longint;
procedure wa; noinline; begin a := 5; end;
procedure wboth; noinline; begin a := 1; b := 2; end;
begin wa; wboth; writeln(a, b); end.
EOF
rep="$("$CC" -Fu"$RTL" -O3 -OoMODREF -OoREPORT "$tmp/rep.pp" -o"$tmp/rep" 2>&1)"

# ---- store-motion kernels -----------------------------------------------------
mk_sm() { # $1 = helper decls, $2 = filename, $3 = in-loop call
  cat > "$tmp/$2" <<EOF
program smt;
{\$mode objfpc}
var g, h: longint; pv: procedure;
$1
function sm(n: longint): longint; noinline;
var i: longint;
begin
  for i:=1 to n do begin g := g + i; $3; end;
  sm := g;
end;
begin g:=0; h:=0; pv:=nil; writeln(sm(5)); end.
EOF
}
promo() { "$CC" -Fu"$RTL" -O3 $1 -OoSTOREMOTION -OoREPORT "$tmp/$2" -o"$tmp/x" 2>&1 | grep -c 'storemotion: promoted' || true; }

# writes only the disjoint static h  -> promotable with per-static precision
mk_sm 'procedure wh; noinline; begin h := h + 1; end;' sm_h.pp 'wh'
# writes the promoted static g       -> must NOT promote
mk_sm 'procedure wg; noinline; begin g := g + 1; end;' sm_g.pp 'wg'
# indirect call                       -> must NOT promote
mk_sm '' sm_i.pp 'pv'
# overflowing writer (9 statics > MODREF_MAXSTATICS=8) -> smask inexact -> refuse
mk_sm 'var s0,s1,s2,s3,s4,s5,s6,s7,s8: longint;
procedure wover; noinline;
begin s0:=0;s1:=1;s2:=2;s3:=3;s4:=4;s5:=5;s6:=6;s7:=7;s8:=8; end;' sm_o.pp 'wover'

only_mod=$(promo "-OoMODREF" sm_h.pp)
only_base=$(promo "" sm_h.pp)
g_mod=$(promo "-OoMODREF" sm_g.pp)
i_mod=$(promo "-OoMODREF" sm_i.pp)
o_mod=$(promo "-OoMODREF" sm_o.pp)

# ---- cross-unit (ppu serialization of the static set) -------------------------
mkdir -p "$tmp/u"
cat > "$tmp/u/mrs.pas" <<'EOF'
unit mrs;
{$mode objfpc}
interface
var counter: longint;    { exported; written by inccounter }
var g: longint;          { same SOURCE NAME as the caller's own g, distinct location }
procedure inccounter;    { writes mrs.counter }
procedure bumpg;         { writes mrs.g (NOT the caller's g) }
implementation
procedure inccounter; noinline; begin counter := counter + 1; end;
procedure bumpg; noinline; begin g := g + 1; end;
end.
EOF
# caller promotes its OWN g while calling bumpg (writes mrs.g) -> distinct -> promote
cat > "$tmp/u/xdisj.pp" <<'EOF'
program xdisj;
{$mode objfpc}
uses mrs;
var g: longint;
function sm(n: longint): longint; noinline;
var i: longint;
begin for i:=1 to n do begin g:=g+i; bumpg; end; sm:=g; end;
begin g:=0; writeln(sm(5)); end.
EOF
# caller promotes mrs.counter while calling inccounter (writes it) -> refuse
cat > "$tmp/u/xsame.pp" <<'EOF'
program xsame;
{$mode objfpc}
uses mrs;
function sm(n: longint): longint; noinline;
var i: longint;
begin for i:=1 to n do begin counter:=counter+i; inccounter; end; sm:=counter; end;
begin counter:=0; writeln(sm(5)); end.
EOF
"$CC" -Fu"$RTL" -O3 -OoMODREF -FE"$tmp/u" "$tmp/u/mrs.pas" >/dev/null 2>&1
xp() { "$CC" -Fu"$RTL" -Fu"$tmp/u" -FU"$tmp/u" -O3 -OoMODREF -OoSTOREMOTION -OoREPORT "$tmp/u/$1" -o"$tmp/u/x" 2>&1 | grep -c 'storemotion: promoted' || true; }
xdisj_mod=$(xp xdisj.pp)
xsame_mod=$(xp xsame.pp)

# ---- DSE per-static -----------------------------------------------------------
# pending static sg accessed only in main; helper writes only disjoint static ug.
cat > "$tmp/dse.pp" <<'EOF'
program dse;
{$mode objfpc}
type TArr = array[0..3] of longint;
var sg: TArr; ug: longint;
procedure wug; noinline; begin ug := ug + 1; end;
begin
  ug := 0;
  sg[0]:=777; sg[1]:=41; sg[2]:=42; sg[3]:=43; wug; sg[0]:=888;
  writeln(sg[0]+sg[1]+sg[2]+sg[3]+ug);
end.
EOF
dse_cnt() { "$CC" -Fu"$RTL" -O3 $1 -Oodeadstore -al -s "$tmp/dse.pp" -FE"$tmp" >/dev/null 2>&1; grep -cE 'movl[[:space:]]+\$777,' "$tmp/dse.s" || true; }
dse_mod=$(dse_cnt "-OoMODREF")
dse_base=$(dse_cnt "-OoPURE")

echo "REPORT:"
echo "$rep" | grep -E 'wa;|wboth;' | grep modref || true
echo "store motion promotions:"
echo "  disjoint writer,   -OoMODREF=$only_mod (expect >=1), baseline=$only_base (expect 0)"
echo "  promoted writer,   -OoMODREF=$g_mod (expect 0)"
echo "  indirect call,     -OoMODREF=$i_mod (expect 0)"
echo "  overflow writer,   -OoMODREF=$o_mod (expect 0)"
echo "  cross-unit disjoint,-OoMODREF=$xdisj_mod (expect >=1)"
echo "  cross-unit same,   -OoMODREF=$xsame_mod (expect 0)"
echo "DSE dead static store 777:"
echo "  -OoMODREF=$dse_mod (expect 0 removed), baseline=$dse_base (expect 1 kept)"

rc=0
echo "$rep" | grep -qE "wa; mod/ref summary: reads nothing, writes unknown-global \[statics [^]]*_A\]" \
  || { echo "FAIL: single-static writer REPORT wrong"; rc=1; }
echo "$rep" | grep -qE "wboth; mod/ref summary: reads nothing, writes unknown-global \[statics [^]]*_A,[^]]*_B\]" \
  || { echo "FAIL: two-static writer REPORT wrong"; rc=1; }
[ "$only_mod" -ge 1 ] || { echo "FAIL: disjoint-static writer not promoted under -OoMODREF"; rc=1; }
[ "$only_base" = "0" ] || { echo "FAIL: promoted without -OoMODREF"; rc=1; }
[ "$g_mod" = "0" ] || { echo "FAIL: promoted static writer wrongly promoted (unsound)"; rc=1; }
[ "$i_mod" = "0" ] || { echo "FAIL: indirect call wrongly promoted"; rc=1; }
[ "$o_mod" = "0" ] || { echo "FAIL: overflowing (>8 statics) writer wrongly promoted"; rc=1; }
[ "$xdisj_mod" -ge 1 ] || { echo "FAIL: cross-unit disjoint static set not honored (ppu serialization)"; rc=1; }
[ "$xsame_mod" = "0" ] || { echo "FAIL: cross-unit same-static writer wrongly promoted (identity mismatch)"; rc=1; }
[ "$dse_mod" = "0" ] || { echo "FAIL: DSE did not remove dead static store across a disjoint-writing call"; rc=1; }
[ "$dse_base" = "1" ] || { echo "FAIL: DSE baseline (no -OoMODREF) wrongly removed the store"; rc=1; }

[ "$rc" -eq 0 ] && echo "PASS: -OoMODREF per-location (per-static) aliasing refines store motion + DSE soundly"
exit "$rc"
