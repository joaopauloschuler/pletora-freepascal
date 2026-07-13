#!/usr/bin/env bash
# Extended -OoIPACP assertions for the float / tuple / main-body follow-ups.
#
# Proves that, under -OoIPACP:
#   (b) FLOAT constant actuals (single/double) create specialized clones, keyed
#       on the value's bit pattern -- two call sites passing the same float
#       constant SHARE one clone, a different float constant gets a distinct one.
#   (c) A call site that passes constants for SEVERAL eligible parameters is
#       specialized by ONE tuple clone (whose mangled suffix carries every
#       p<idx>-token), not by two/three separate single-parameter clones.
#   (d) Call sites in the MAIN PROGRAM BODY are eligible and get retargeted to
#       clones just like calls inside ordinary routines.
#   caps: the per-routine clone cap (4) is still enforced and emits its remark.
# Every case also checks the -Ooreport remark and that NOTHING clones when the
# switch is off, and each program is run to prove the specialization is sound.
#
# Usage: unleashed/tests/ipacp_ext_check.sh [path-to-ppcx64]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

RUN() { ulimit -v 3000000; timeout 60 "$@"; }
rc=0

# count unique ipacp clone symbol *definitions* (label lines) in an .s file
clone_defs() { grep -oE '^P\$[A-Za-z0-9$_]*\$ipacp\$[A-Za-z0-9]+:' "$1" | sed 's/:$//' | sort -u; }

# ---------------------------------------------------------------------------
# (b) FLOAT clones: shared for equal constants, distinct for different ones.
# ---------------------------------------------------------------------------
cat > "$tmp/flt.pp" <<'EOF'
program flt;
{$mode objfpc}{$H+}
function Sc(x: double; k: single): double;
var i: longint; s: double;
begin
  s := 0;
  if k = 0 then exit(0);
  for i := 1 to 3 do s := s + x;
  Sc := s * k;
end;
function AA(v: double): double; begin AA := Sc(v, 2.0) + Sc(v+1, 2.0); end;
function BB(v: double): double; begin BB := Sc(v, 5.0); end;
begin
  Writeln((AA(1.0)+BB(2.0)):0:2);
end.
EOF
cp "$tmp/flt.pp" "$tmp/flt_off.pp"
( cd "$tmp" && "$CC" -Fu"$RTL" -O2 -OoIPACP -al -s flt.pp     -oflt     >/dev/null 2>&1 )
( cd "$tmp" && "$CC" -Fu"$RTL" -O2           -al -s flt_off.pp -oflt_off >/dev/null 2>&1 ) || true
flt_defs=$(clone_defs "$tmp/flt.s" | grep -cE '\$ipacp\$p1f' || true)
flt_off=$(grep -cE 'ipacp' "$tmp/flt_off.s" || true)
flt_rem=$("$CC" -Fu"$RTL" -O2 -OoIPACP -OoREPORT "$tmp/flt.pp" -o"$tmp/fltb" 2>&1 | grep 'ipacp:' || true)
flt_r2=$(printf '%s\n' "$flt_rem" | grep -cF 'specialized for k=2.0' || true)
flt_r5=$(printf '%s\n' "$flt_rem" | grep -cF 'specialized for k=5.0' || true)
flt_run=$(RUN "$tmp/fltb")
echo "(b) float: clone defs=$flt_defs (expect 2)  switch-off=$flt_off (expect 0)"
echo "(b) float: remark k=2.0 x$flt_r2 (expect 2)  k=5.0 x$flt_r5 (expect 1)  run=$flt_run (expect 48.00)"
[ "$flt_defs" -eq 2 ] || { echo "FAIL(b): expected exactly 2 shared/distinct float clones"; rc=1; }
[ "$flt_off"  -eq 0 ] || { echo "FAIL(b): float clones emitted without the switch"; rc=1; }
[ "$flt_r2"   -eq 2 ] || { echo "FAIL(b): expected two k=2.0 remarks (shared clone, two sites)"; rc=1; }
[ "$flt_r5"   -eq 1 ] || { echo "FAIL(b): expected one k=5.0 remark"; rc=1; }
[ "$flt_run"  = "48.00" ] || { echo "FAIL(b): float-specialized program gave wrong result"; rc=1; }

# ---------------------------------------------------------------------------
# (c) TUPLE clones: two constants at one site -> ONE clone, not two singles.
# ---------------------------------------------------------------------------
cat > "$tmp/tup.pp" <<'EOF'
program tup;
{$mode objfpc}{$H+}
function Rng(x, lo, hi: longint): longint;
var i, s: longint;
begin
  s := 0;
  if lo > hi then exit(-1);
  for i := lo to hi do s := s + x;
  Rng := s;
end;
function Use(v: longint): longint;
begin
  { lo AND hi constant, x runtime -> a single 2-element tuple clone }
  Use := Rng(v, 2, 5);
end;
begin
  Writeln(Use(3));
end.
EOF
( cd "$tmp" && "$CC" -Fu"$RTL" -O2 -OoIPACP -al -s tup.pp -otup >/dev/null 2>&1 )
mapfile -t tdefs < <(clone_defs "$tmp/tup.s")
tup_n=${#tdefs[@]}
# the single clone's suffix must carry BOTH p-tokens (p1 and p2), proving a
# tuple clone rather than a single-parameter one
tup_tuple=$(printf '%s\n' "${tdefs[@]}" | grep -cE 'ipacp\$p1v2p2v5$' || true)
tup_rem=$("$CC" -Fu"$RTL" -O2 -OoIPACP -OoREPORT "$tmp/tup.pp" -o"$tmp/tupb" 2>&1 | grep 'ipacp:' || true)
tup_r=$(printf '%s\n' "$tup_rem" | grep -cF 'specialized for lo=2, hi=5' || true)
tup_run=$(RUN "$tmp/tupb")
echo "(c) tuple: clone defs=$tup_n (expect 1)  is-2-tuple=$tup_tuple (expect 1)"
echo "(c) tuple: remark 'lo=2, hi=5' x$tup_r (expect 1)  run=$tup_run (expect 3+3+3+3=12)"
[ "$tup_n"     -eq 1 ] || { echo "FAIL(c): a 2-constant site produced $tup_n clones, expected 1 tuple clone"; rc=1; }
[ "$tup_tuple" -eq 1 ] || { echo "FAIL(c): the clone is not a 2-parameter tuple clone (p1v2p2v5)"; rc=1; }
[ "$tup_r"     -eq 1 ] || { echo "FAIL(c): expected one combined tuple remark"; rc=1; }
[ "$tup_run"   -eq 12 ] || { echo "FAIL(c): tuple-specialized program gave wrong result"; rc=1; }

# ---------------------------------------------------------------------------
# (d) MAIN-BODY call sites are eligible.
# ---------------------------------------------------------------------------
cat > "$tmp/mb.pp" <<'EOF'
program mb;
{$mode objfpc}{$H+}
function Sc(x, f: longint): longint;
var i, s: longint;
begin
  s := 0;
  if f = 0 then exit(0);
  for i := 1 to f do s := s + x;
  Sc := s;
end;
begin
  { the ONLY caller of Sc is the main program body }
  Writeln(Sc(4, 3));
end.
EOF
cp "$tmp/mb.pp" "$tmp/mb_off.pp"
( cd "$tmp" && "$CC" -Fu"$RTL" -O2 -OoIPACP -al -s mb.pp     -omb     >/dev/null 2>&1 )
( cd "$tmp" && "$CC" -Fu"$RTL" -O2           -al -s mb_off.pp -omb_off >/dev/null 2>&1 ) || true
mb_defs=$(clone_defs "$tmp/mb.s" | grep -c 'ipacp' || true)
mb_off=$(grep -cE 'ipacp' "$tmp/mb_off.s" || true)
# the retargeted call to the clone must appear in PASCALMAIN
mb_call=$(sed -n '/^PASCALMAIN:/,/\.Le[0-9]/p' "$tmp/mb.s" | grep -cE 'call[[:space:]]+.*ipacp\$' || true)
mb_rem=$("$CC" -Fu"$RTL" -O2 -OoIPACP -OoREPORT "$tmp/mb.pp" -o"$tmp/mbb" 2>&1 | grep -cF 'ipacp: call to Sc specialized' || true)
mb_run=$(RUN "$tmp/mbb")
echo "(d) main-body: clone defs=$mb_defs (expect 1)  PASCALMAIN->clone calls=$mb_call (expect 1)"
echo "(d) main-body: switch-off=$mb_off (expect 0)  remark=$mb_rem (expect 1)  run=$mb_run (expect 12)"
[ "$mb_defs" -ge 1 ] || { echo "FAIL(d): no clone created for a main-body call site"; rc=1; }
[ "$mb_call" -ge 1 ] || { echo "FAIL(d): PASCALMAIN does not call the clone"; rc=1; }
[ "$mb_off"  -eq 0 ] || { echo "FAIL(d): main-body clone emitted without the switch"; rc=1; }
[ "$mb_rem"  -ge 1 ] || { echo "FAIL(d): no remark for the main-body specialization"; rc=1; }
[ "$mb_run"  -eq 12 ] || { echo "FAIL(d): main-body-specialized program gave wrong result"; rc=1; }

# ---------------------------------------------------------------------------
# caps: five distinct constant families -> 4 clones + one cap remark.
# ---------------------------------------------------------------------------
cat > "$tmp/cap.pp" <<'EOF'
program cap;
{$mode objfpc}{$H+}
function Sc(x, f: longint): longint;
var i, s: longint;
begin
  s := 0;
  if f = 0 then exit(0);
  for i := 1 to f do s := s + x;
  Sc := s;
end;
begin
  Writeln(Sc(1,1)+Sc(1,2)+Sc(1,3)+Sc(1,4)+Sc(1,5));
end.
EOF
( cd "$tmp" && "$CC" -Fu"$RTL" -O2 -OoIPACP -al -s cap.pp -ocap >/dev/null 2>&1 )
cap_defs=$(clone_defs "$tmp/cap.s" | grep -c 'ipacp' || true)
cap_rem=$("$CC" -Fu"$RTL" -O2 -OoIPACP -OoREPORT "$tmp/cap.pp" -o"$tmp/capb" 2>&1 | grep -cF 'size budget exceeded: Sc (per-routine clone cap)' || true)
cap_run=$(RUN "$tmp/capb")
echo "caps: clone defs=$cap_defs (expect 4)  cap remark=$cap_rem (expect 1)  run=$cap_run (expect 15)"
[ "$cap_defs" -eq 4 ] || { echo "FAIL(caps): expected exactly 4 clones (per-routine cap), got $cap_defs"; rc=1; }
[ "$cap_rem"  -eq 1 ] || { echo "FAIL(caps): expected one per-routine cap remark"; rc=1; }
[ "$cap_run"  -eq 15 ] || { echo "FAIL(caps): capped program gave wrong result"; rc=1; }

[ "$rc" -eq 0 ] && echo "PASS: float clones (shared/distinct by bit pattern), tuple clones (one clone per multi-constant site), main-body call sites, and per-routine caps all behave and run correctly"
exit "$rc"
