#!/usr/bin/env bash
# -OoPURE nothrow attribute: independent tracking + a sound, observable consumer.
#
# The interprocedural purity pass now tracks "cannot raise/trap" (NOTHROW) as its
# OWN bit, decoupled from purity: the pure/const verdict is unchanged (still folds
# trapping in), but a nothrow verdict is available even for an IMPURE routine, and
# a MEM-PURE (writes-no-memory) verdict is available even for a routine that may
# trap. Both are serialized alongside pure/const in the optsum_pure ppu summary
# (CurrentPPULongVersion bumped; ppudump dumps them).
#
# Consumer: -OoLICM hoists a loop-invariant call to a proven MEM-PURE + NOTHROW
# target into the preheader (even for a possibly zero-trip loop) when the loop
# body writes no memory. The NOTHROW bit supplies the "safe to speculate"
# guarantee CONST used to stand in for; a mem-pure call that may still TRAP is
# correctly rejected.
#
# Proves:
#   1. independence: an IMPURE-but-nothrow routine gets a nothrow -vh hint and is
#      NOT reported pure/const; a may-trap routine gets NO nothrow hint;
#   2. same-unit consumer: a mem-pure+nothrow invariant call is hoisted (remark),
#      a mem-pure may-TRAP invariant call is NOT -- only with -OoPURE;
#   3. cross-unit: the hoist fires for a nothrow routine loaded from another
#      unit's ppu (exercising the serialized nothrow/mempure bits end-to-end);
#   4. runtime: a zero-trip loop containing a may-trap call with a zero divisor
#      runs clean (the call was not speculatively hoisted), and a nothrow
#      invariant call gives the same result hoisted or not.
#
# Usage: unleashed/tests/pure_nothrow_check.sh [path-to-ppcx64]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

HOISTRE='hoisted a proven mem-pure \+ NOTHROW loop-invariant call into the preheader'

# ---------------------------------------------------------------------------
# 1. Independence of the nothrow verdict (-vh hints).
# ---------------------------------------------------------------------------
cat > "$tmp/v.pp" <<'EOF'
{$mode objfpc}
program v;
var gv: longint;
function nf(i: longint): longint;  begin nf := gv + i; end;          { pure+nothrow }
procedure setg(v: longint);        begin gv := v; end;               { impure+nothrow }
function tf(i: longint): longint;  begin tf := (100 div gv) + i; end;{ mem-pure, may trap }
begin setg(3); writeln(nf(1)+tf(1)); end.
EOF
vh="$("$CC" -Fu"$RTL" -O2 -OoPURE -vh "$tmp/v.pp" 2>&1 || true)"

# ---------------------------------------------------------------------------
# 2. Same-unit consumer (remark assertions).
# ---------------------------------------------------------------------------
cat > "$tmp/nf.pp" <<'EOF'
{$mode objfpc}
program nfp;
var gv: longint;
function nf(i: longint): longint; begin nf := gv + i; end;
function run(n, k: longint): longint;
var i, s: longint;
begin s := 0; for i := 1 to n do s := s + nf(k); run := s; end;
begin gv := 10; writeln(run(ParamCount + 5, 7)); end.
EOF
cat > "$tmp/tf.pp" <<'EOF'
{$mode objfpc}
program tfp;
var gv: longint;
function tf(i: longint): longint; begin tf := (100 div gv) + i; end;
function run(n, k: longint): longint;
var i, s: longint;
begin s := 0; for i := 1 to n do s := s + tf(k); run := s; end;
begin gv := 0; writeln('ok ', run(ParamCount, 7)); end.
EOF
nf_on=$( "$CC" -Fu"$RTL" -O4 -OoPURE -OoLICM -OoREPORT "$tmp/nf.pp" -o"$tmp/nfb" 2>&1 | grep -cE "$HOISTRE" || true)
nf_off=$("$CC" -Fu"$RTL" -O4          -OoLICM -OoREPORT "$tmp/nf.pp" -o"$tmp/nfc" 2>&1 | grep -cE "$HOISTRE" || true)
tf_on=$( "$CC" -Fu"$RTL" -O4 -OoPURE -OoLICM -OoREPORT "$tmp/tf.pp" -o"$tmp/tfb" 2>&1 | grep -cE "$HOISTRE" || true)
nf_out="$( ulimit -v 3000000; timeout 30 "$tmp/nfb" )"; nf_rc=$?
tf_out="$( ulimit -v 3000000; timeout 30 "$tmp/tfb" )"; tf_rc=$?

# ---------------------------------------------------------------------------
# 3. Cross-unit: the nothrow/mempure bits survive the ppu round trip.
# ---------------------------------------------------------------------------
cat > "$tmp/nu.pas" <<'EOF'
{$mode objfpc}
unit nu;
interface
var gv: longint;
function nf(i: longint): longint;
implementation
function nf(i: longint): longint; begin nf := gv + i; end;
end.
EOF
cat > "$tmp/mn.pas" <<'EOF'
{$mode objfpc}
program mn;
uses nu;
function run(n, k: longint): longint;
var i, s: longint;
begin s := 0; for i := 1 to n do s := s + nf(k); run := s; end;
begin gv := 4; writeln(run(ParamCount + 3, 5)); end.
EOF
"$CC" -Fu"$RTL" -O2 -OoPURE -FE"$tmp" "$tmp/nu.pas" >/dev/null 2>&1
xu_on=$( "$CC" -Fu"$RTL" -Fu"$tmp" -FE"$tmp" -O4 -OoPURE -OoLICM -OoREPORT "$tmp/mn.pas" -o"$tmp/mnb" 2>&1 | grep -cE "$HOISTRE" || true)
xu_out="$( ulimit -v 3000000; timeout 30 "$tmp/mnb" )"; xu_rc=$?

# ---------------------------------------------------------------------------
# 4. The suite runtime fixture (zero-trip trap-safety + hoist correctness).
# ---------------------------------------------------------------------------
fix="$root/unleashed/tests/testfiles/optlicm/licm_nothrow_01.pp"
"$CC" -Fu"$RTL" -O4 -OoPURE -OoLICM "$fix" -o"$tmp/fixb" >/dev/null 2>&1
fix_out="$( ulimit -v 3000000; timeout 30 "$tmp/fixb" )"; fix_rc=$?

echo "HINTS  : $(printf '%s\n' "$vh" | grep -cE 'setg.* proven nothrow') setg-nothrow (1), $(printf '%s\n' "$vh" | grep -cE 'setg.* proven (pure|const)') setg-pure (0), $(printf '%s\n' "$vh" | grep -cE 'nf.* proven nothrow') nf-nothrow (1), $(printf '%s\n' "$vh" | grep -cE 'tf.* proven nothrow') tf-nothrow (0)"
echo "SAMEUNIT: nf_on=$nf_on (>=1) nf_off=$nf_off (0) tf_on=$tf_on (0)  nf_out='$nf_out' (85) tf_out='$tf_out' (ok 0)"
echo "CROSSUNIT: xu_on=$xu_on (>=1) xu_out='$xu_out' (27) rc=$xu_rc"
echo "FIXTURE : out='$fix_out' (ok) rc=$fix_rc"

rc=0
printf '%s\n' "$vh" | grep -qE 'setg[^"]*" proven nothrow' || { echo "FAIL: impure setg not reported nothrow (independence)"; rc=1; }
printf '%s\n' "$vh" | grep -qE 'setg[^"]*" proven (pure|const)' && { echo "FAIL: impure setg wrongly reported pure/const"; rc=1; } || true
printf '%s\n' "$vh" | grep -qE 'nf[^"]*" proven nothrow' || { echo "FAIL: nf not reported nothrow"; rc=1; }
printf '%s\n' "$vh" | grep -qE 'tf[^"]*" proven nothrow' && { echo "FAIL: may-trap tf wrongly reported nothrow"; rc=1; } || true
[ "$nf_on"  -ge 1 ] || { echo "FAIL: mem-pure+nothrow call not hoisted with -OoPURE"; rc=1; }
[ "$nf_off" -eq 0 ] || { echo "FAIL: nothrow hoist fired without -OoPURE"; rc=1; }
[ "$tf_on"  -eq 0 ] || { echo "FAIL: may-trap call was hoisted (unsound)"; rc=1; }
[ "$nf_out" = "85" ] || { echo "FAIL: nf result wrong '$nf_out'"; rc=1; }
[ "$nf_rc" -eq 0 ]   || { echo "FAIL: nf program crashed rc=$nf_rc"; rc=1; }
[ "$tf_out" = "ok 0" ] || { echo "FAIL: tf result wrong '$tf_out'"; rc=1; }
[ "$tf_rc" -eq 0 ]   || { echo "FAIL: tf zero-trip program crashed (may-trap call hoisted?) rc=$tf_rc"; rc=1; }
[ "$xu_on"  -ge 1 ] || { echo "FAIL: cross-unit nothrow call not hoisted (ppu bits lost)"; rc=1; }
[ "$xu_out" = "27" ] || { echo "FAIL: cross-unit result wrong '$xu_out'"; rc=1; }
[ "$xu_rc" -eq 0 ]   || { echo "FAIL: cross-unit program crashed rc=$xu_rc"; rc=1; }
[ "$fix_out" = "ok" ] || { echo "FAIL: fixture result wrong '$fix_out'"; rc=1; }
[ "$fix_rc" -eq 0 ]  || { echo "FAIL: fixture crashed (zero-trip trap hoisted?) rc=$fix_rc"; rc=1; }

[ "$rc" -eq 0 ] && echo "PASS: nothrow tracked independently of purity (impure setg is nothrow, may-trap tf is not); -OoLICM hoists a mem-pure+nothrow invariant call same-unit AND cross-unit, refuses a may-trap one; zero-trip + may-trap call runs clean (not speculatively hoisted); all only under -OoPURE"
exit "$rc"
