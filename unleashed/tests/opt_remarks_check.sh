#!/usr/bin/env bash
# Diagnostic assertion for the -Ooreport optimization-remarks facility (the gcc
# -fopt-info / clang -Rpass counterpart shared by the fork's -Oo* loop passes).
#
# When -Ooreport is set each covered pass emits one structured line per APPLIED
# transform and -- the more valuable half -- one per MISSED transform naming the
# concrete blocking reason, at the position of the affected loop, prefixed by
# the pass name and with NO Note:/Hint: label:
#
#   file.pp(L,C): vectorize: loop vectorized, VF=4, tail=scalar
#   file.pp(L,C): vectorize: not vectorized: <reason>
#
# This script proves (a) an applied remark fires for a known-vectorizable loop,
# (b) a missed remark with the real reason fires for a known-blocked loop,
# (c) NONE of these unlabelled remark lines appear when -Ooreport is off, and
# (d) enabling -Ooreport is measure-only: the emitted assembly is bit-identical
# with the switch on vs off.
#
# Usage: unleashed/tests/opt_remarks_check.sh [path-to-ppcx64]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A vectorizable single-precision element-wise loop (applied) and a loop blocked
# by a two-statement body that also stores to a var-parameter (missed).
cat > "$tmp/k.pp" <<'EOF'
program k;
{$mode objfpc}{$H+}
type TS = array of single;
procedure work(a,b,c: TS; n: longint; var g: single);
var i: longint;
begin
  for i:=0 to n-1 do a[i]:=b[i]+c[i];
  for i:=0 to n-1 do begin a[i]:=b[i]-c[i]; g:=g+a[i]; end;
end;
var a,b,c: TS; i: longint; g: single;
begin
  SetLength(a,64); SetLength(b,64); SetLength(c,64);
  for i:=0 to 63 do begin b[i]:=i; c[i]:=i; end;
  g:=0; work(a,b,c,64,g);
  writeln(a[0]:0:1,' ',g:0:1);
end.
EOF

on="$( "$CC" -Fu"$RTL" -O4 -OoVECTORIZE -OoREPORT -Cfsse64 "$tmp/k.pp" 2>&1 || true )"
off="$("$CC" -Fu"$RTL" -O4 -OoVECTORIZE          -Cfsse64 "$tmp/k.pp" 2>&1 || true )"

echo "--- remarks with -OoREPORT ---"
grep -E ' (vectorize|ifconvert|loopsplit|loopfuse|reassoc|looppeel|unrolljam|unrolldyn|licm|finalvalue): ' <<<"$on" || true

rc=0
# (a) applied remark for the vectorizable loop (line 7)
grep -qE 'k\.pp\(7,[0-9]+\) vectorize: loop vectorized, VF=4, tail=scalar$' <<<"$on" \
  || { echo "FAIL: missing applied vectorize remark"; rc=1; }
# (b) missed remark naming the concrete blocking reason for the blocked loop (line 8)
grep -qE 'k\.pp\(8,[0-9]+\) vectorize: not vectorized: loop body is empty or has multiple statements$' <<<"$on" \
  || { echo "FAIL: missing missed vectorize remark with reason"; rc=1; }
# (c) no unlabelled pass-prefixed remark line at all when the switch is off
grep -qE ' vectorize: (not vectorized|loop vectorized)' <<<"$off" \
  && { echo "FAIL: remark emitted without -OoREPORT"; rc=1; } || true

# (d) bit-identical codegen with remarks on vs off
mkdir -p "$tmp/x" "$tmp/y"; cp "$tmp/k.pp" "$tmp/x/"; cp "$tmp/k.pp" "$tmp/y/"
( cd "$tmp/x" && "$CC" -Fu"$RTL" -O4 -OoVECTORIZE          -Cfsse64 -al -s k.pp >/dev/null 2>&1 )
( cd "$tmp/y" && "$CC" -Fu"$RTL" -O4 -OoVECTORIZE -OoREPORT -Cfsse64 -al -s k.pp >/dev/null 2>&1 )
if diff -q "$tmp/x/k.s" "$tmp/y/k.s" >/dev/null; then
  echo "codegen bit-identical: on == off"
else
  echo "FAIL: -OoREPORT changed the generated assembly"; rc=1
fi

# ---------------------------------------------------------------------------
# Extended coverage: the remaining -Oo* passes threaded through the remarks
# facility (optdeadstore, opttail/SIBCALL, optpure, GVN-PRE, PREDCOM,
# SWITCHTABLE, BITIDIOM, SLP, STOREMERGE, STACKALLOC, ICF). For each we assert
# a representative APPLIED ("transformed") remark and -- where the pass has a
# meaningful whole-transform bail-out -- a MISSED ("bailed because X") remark,
# and that both are silent without -OoREPORT.
# ---------------------------------------------------------------------------

# helper: assert a remark regex is present in $1 (the compiler output)
want() { grep -qE "$2" <<<"$1" || { echo "FAIL: missing remark: $2"; rc=1; }; }
# helper: assert NO pass-prefixed remark for the given pass appears in $1
none() { grep -qE " $2: " <<<"$1" && { echo "FAIL: $2 remark emitted without -OoREPORT"; rc=1; } || true; }

# --- optpure: verdict (applied) + why-not (bailed) --------------------------
cat > "$tmp/pure.pp" <<'EOF'
program pure;
{$mode objfpc}
var glob: longint;
function clean(x,y: longint): longint;
begin clean:=x*y+1; end;
function dirty(x: longint): longint;
begin glob:=glob+x; dirty:=glob; end;
begin writeln(clean(2,3),' ',dirty(4)); end.
EOF
pon="$("$CC" -Fu"$RTL" -O4 -OoPURE -OoREPORT "$tmp/pure.pp" 2>&1 || true)"
poff="$("$CC" -Fu"$RTL" -O4 -OoPURE          "$tmp/pure.pp" 2>&1 || true)"
want "$pon" 'pure\.pp\(4,[0-9]+\) pure: .* proven const'
want "$pon" 'pure\.pp\(6,[0-9]+\) pure: .* not pure/const: '
none "$poff" 'pure'

# --- opttail / tail recursion: applied + bailed (managed parameter) ---------
cat > "$tmp/tr.pp" <<'EOF'
program tr;
{$mode objfpc}{$H+}
function fact(n, acc: longint): longint;
begin if n<=1 then fact:=acc else fact:=fact(n-1, acc*n); end;
function g(s: ansistring; n: longint): longint;
begin if n<=0 then g:=length(s) else g:=g(s,n-1); end;
begin writeln(fact(5,1),' ',g('hi',2)); end.
EOF
ton="$("$CC" -Fu"$RTL" -O4 -OoTAILREC -OoREPORT "$tmp/tr.pp" 2>&1 || true)"
toff="$("$CC" -Fu"$RTL" -O4 -OoTAILREC          "$tmp/tr.pp" 2>&1 || true)"
want "$ton" 'tr\.pp\(3,[0-9]+\) tailrec: .* rewritten into a loop'
want "$ton" 'tr\.pp\(5,[0-9]+\) tailrec: .* not applied: parameter .* managed'
none "$toff" 'tailrec'

# --- optdeadstore: applied + bailed (nested procedures) ---------------------
cat > "$tmp/ds.pp" <<'EOF'
program ds;
{$mode objfpc}
function f(x: longint): longint;
var t: longint;
begin t:=x+1; t:=x*2; f:=t; end;
function outer(x: longint): longint;
  function inner(y: longint): longint;
  begin inner:=y+1; end;
var t: longint;
begin t:=x+1; t:=x*2; outer:=inner(t); end;
begin writeln(f(3),' ',outer(4)); end.
EOF
dson="$("$CC" -Fu"$RTL" -O4 -Oodeadstore -OoREPORT "$tmp/ds.pp" 2>&1 || true)"
dsoff="$("$CC" -Fu"$RTL" -O4 -Oodeadstore          "$tmp/ds.pp" 2>&1 || true)"
want "$dson" 'ds\.pp\(3,[0-9]+\) deadstore: removed one or more stores'
want "$dson" 'ds\.pp\(6,[0-9]+\) deadstore: .*skipped: routine has nested procedures'
none "$dsoff" 'deadstore'

# --- GVN-PRE: applied -------------------------------------------------------
cat > "$tmp/gv.pp" <<'EOF'
program gv;
{$mode objfpc}
var g1,g2: longint;
procedure f(a,b: longint);
begin g1:=(a+b)*(a-b); g2:=(a+b)*(a-b); end;
begin f(5,3); writeln(g1,' ',g2); end.
EOF
gon="$("$CC" -Fu"$RTL" -O4 -OoGVNPRE -OoREPORT "$tmp/gv.pp" 2>&1 || true)"
goff="$("$CC" -Fu"$RTL" -O4 -OoGVNPRE          "$tmp/gv.pp" 2>&1 || true)"
want "$gon" 'gv\.pp\([0-9]+,[0-9]+\) gvnpre: eliminated [0-9]+ fully-redundant'
none "$goff" 'gvnpre'

# --- BITIDIOM: applied (popcount idiom) -------------------------------------
cat > "$tmp/bit.pp" <<'EOF'
program bit;
function popc(x: longword): longint;
var c: longint;
begin c:=0; while x<>0 do begin x:=x and (x-1); inc(c); end; popc:=c; end;
begin writeln(popc(255)); end.
EOF
bon="$("$CC" -Fu"$RTL" -O4 -OoBITIDIOM -OoREPORT "$tmp/bit.pp" 2>&1 || true)"
boff="$("$CC" -Fu"$RTL" -O4 -OoBITIDIOM          "$tmp/bit.pp" 2>&1 || true)"
want "$bon" 'bit\.pp\([0-9]+,[0-9]+\) bitidiom: .*PopCnt'
none "$boff" 'bitidiom'

# --- SWITCHTABLE: applied ---------------------------------------------------
cat > "$tmp/sw.pp" <<'EOF'
program sw;
var e,a: longint;
begin
  for e:=0 to 4 do begin
    case e of 0:a:=10; 1:a:=20; 2:a:=30; 3:a:=40; 4:a:=50; end;
    writeln(a);
  end;
end.
EOF
swon="$("$CC" -Fu"$RTL" -O4 -OoSWITCHTABLE -OoREPORT "$tmp/sw.pp" 2>&1 || true)"
swoff="$("$CC" -Fu"$RTL" -O4 -OoSWITCHTABLE          "$tmp/sw.pp" 2>&1 || true)"
want "$swon" 'sw\.pp\([0-9]+,[0-9]+\) switchtable: .*lookup table'
none "$swoff" 'switchtable'

# --- STACKALLOC: applied ----------------------------------------------------
cat > "$tmp/sa.pp" <<'EOF'
program sa;
{$mode objfpc}{$H+}
function sumn: longint;
var a: array of longint; i,s: longint;
begin
  SetLength(a,16);
  for i:=0 to 15 do a[i]:=i;
  s:=0; for i:=0 to 15 do s:=s+a[i];
  sumn:=s;
end;
begin writeln(sumn); end.
EOF
saon="$("$CC" -Fu"$RTL" -O4 -OoSTACKALLOC -OoREPORT "$tmp/sa.pp" 2>&1 || true)"
saoff="$("$CC" -Fu"$RTL" -O4 -OoSTACKALLOC          "$tmp/sa.pp" 2>&1 || true)"
want "$saon" 'sa\.pp\([0-9]+,[0-9]+\) stackalloc: .*promoted from the heap'
none "$saoff" 'stackalloc'

# --- SLP: applied (straight-line pack) --------------------------------------
cat > "$tmp/slp.pp" <<'EOF'
program slp;
{$mode objfpc}{$H+}
type TA = array of single;
procedure go(a,b,c: TA);
begin
  a[0]:=b[0]+c[0]; a[1]:=b[1]+c[1]; a[2]:=b[2]+c[2]; a[3]:=b[3]+c[3];
end;
var a,b,c: TA; i: longint;
begin
  SetLength(a,4);SetLength(b,4);SetLength(c,4);
  for i:=0 to 3 do begin b[i]:=i; c[i]:=i; end;
  go(a,b,c); writeln(a[0]:0:1);
end.
EOF
slon="$("$CC" -Fu"$RTL" -O4 -OoSLP -OoREPORT -Cfsse64 "$tmp/slp.pp" 2>&1 || true)"
sloff="$("$CC" -Fu"$RTL" -O4 -OoSLP          -Cfsse64 "$tmp/slp.pp" 2>&1 || true)"
want "$slon" 'slp\.pp\([0-9]+,[0-9]+\) slp: .*packed into one 128-bit SSE'
none "$sloff" 'slp'

# --- STOREMERGE: applied (asm-level) ----------------------------------------
cat > "$tmp/sm.pp" <<'EOF'
program sm;
{$mode objfpc}
type TR = packed record a,b,c,d: byte; end;
procedure fill(var r: TR);
begin r.a:=1; r.b:=2; r.c:=3; r.d:=4; end;
var r: TR;
begin fill(r); writeln(r.a,r.b,r.c,r.d); end.
EOF
smon="$("$CC" -Fu"$RTL" -O4 -OoREPORT "$tmp/sm.pp" 2>&1 || true)"
smoff="$("$CC" -Fu"$RTL" -O4          "$tmp/sm.pp" 2>&1 || true)"
want "$smon" 'sm\.pp\([0-9]+,[0-9]+\) storemerge: coalesced [0-9]+ adjacent constant stores'
none "$smoff" 'storemerge'

# --- SIBCALL: applied (asm-level) -------------------------------------------
# the sibling-call recognizer needs the specific frame/teardown shape (a value
# held live across an inner call, forcing a callee-saved register), so drive the
# committed fixture rather than a minimal reduction.
cp "$root/unleashed/tests/testfiles/optsibcall/optsibcall_deep_pop_01.pp" "$tmp/optsibcall_deep_pop_01.pp"
scfix="$tmp/optsibcall_deep_pop_01.pp"
scon="$("$CC" -Fu"$RTL" -O2 -OoSIBCALL -OoREPORT "$scfix" 2>&1 || true)"
scoff="$("$CC" -Fu"$RTL" -O2 -OoSIBCALL          "$scfix" 2>&1 || true)"
want "$scon" 'optsibcall_deep_pop_01\.pp\([0-9]+,[0-9]+\) sibcall: tail call turned into a jump'
none "$scoff" 'sibcall'

# --- ICF: applied (asm-level, byte-identical routine folding) ---------------
cat > "$tmp/icf.pp" <<'EOF'
program icf;
{$mode objfpc}
function foo(a,b,c,d: longint): longint; begin foo:=a*b+c-d; end;
function bar(a,b,c,d: longint): longint; begin bar:=a*b+c-d; end;
begin writeln(foo(1,2,3,4),' ',bar(5,6,7,8)); end.
EOF
icon="$("$CC" -Fu"$RTL" -O2 -OoICF -OoREPORT "$tmp/icf.pp" 2>&1 || true)"
icoff="$("$CC" -Fu"$RTL" -O2 -OoICF          "$tmp/icf.pp" 2>&1 || true)"
want "$icon" 'icf: byte-identical routine .* folded onto'
none "$icoff" 'icf'

# bit-identical codegen for a representative newly-covered pass (PURE + DSE):
# remarks must be measure-only across every covered switch.
mkdir -p "$tmp/px" "$tmp/py"; cp "$tmp/ds.pp" "$tmp/px/"; cp "$tmp/ds.pp" "$tmp/py/"
( cd "$tmp/px" && "$CC" -Fu"$RTL" -O4 -OoPURE -Oodeadstore          -al -s ds.pp >/dev/null 2>&1 )
( cd "$tmp/py" && "$CC" -Fu"$RTL" -O4 -OoPURE -Oodeadstore -OoREPORT -al -s ds.pp >/dev/null 2>&1 )
if diff -q "$tmp/px/ds.s" "$tmp/py/ds.s" >/dev/null; then
  echo "codegen bit-identical (pure+deadstore): on == off"
else
  echo "FAIL: -OoREPORT changed the generated assembly for pure/deadstore"; rc=1
fi

[ "$rc" -eq 0 ] && echo "PASS: -Ooreport emits applied+missed remarks, silent when off, codegen unchanged"
exit "$rc"
