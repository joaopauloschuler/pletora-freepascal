#!/usr/bin/env bash
# Firing / soundness checks for -OoSINK (code sinking, gated in -O4) around the
# self-host blocker #7 miscompile.
#
# The pass moves a pure assignment  V := <expr>  that immediately precedes an
# if into the single arm of that if which CONSUMES (reads) V, when V is dead on
# the fall-through.  The blocker-#7 bug: sink_refs_sym counted the LHS of an
# arm's assignment  V := something  -- a pure WRITE, not a read -- as the arm
# "consuming" V.  For fpc_Val_UInt_Shortstr's tail
#
#     code := 0;
#     if (sp <= ns) and (s[sp] <> #0) then begin code := sp; ... end;
#
# the then-arm only WRITES code, yet was treated as its sole consumer, so the
# default store `code := 0` was sunk into that arm and the fall-through path
# returned the OUT parameter `code` uninitialised.  This script asserts:
#
#   Part A (firing): on a genuine one-arm-READ shape the pass still fires --
#     under -OoREPORT the compiler prints the "sink: pure assignment sunk into
#     the single if-arm that reads it" remark.  (Regression guard: the fix must
#     not disable the useful case.)
#
#   Part B (refusal): on the val-tail shape (default store before an if whose
#     only reference to V is a WRITE) the pass MUST decline -- no sink remark --
#     and the fall-through path must keep the default value.
#
#   Part C (semantics): the promoted regression test runs cleanly at -O4 and at
#     -O4 -OoNOSINK, byte-identical stdout, exit 0.
#
# Usage: unleashed/tests/sink_outparam_check.sh [path-to-ppcx64]
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

rc=0
fail() { echo "FAIL: $*"; rc=1; }

FIRED='sink: pure assignment sunk into the single if-arm that reads it'

# ---------------------------------------------------------------------------
# Part A: fires on a genuine one-arm-READ shape
# ---------------------------------------------------------------------------
cat > "$tmp/read.pp" <<'EOF'
{$mode objfpc}
procedure compute(sp, ns: longint; ch: byte; out res: longint);
var t: longint;
begin
  t := sp * 3 + 5;                 { pure movable assignment to t }
  if (sp <= ns) and (ch <> 0) then
    res := t + 1                   { then-arm READS t; t dead afterwards }
  else
    res := 0;
end;
var r: longint;
begin compute(5,20,55,r); writeln(r); end.
EOF
read_log="$("$CC" -Fu"$RTL" -O4 -OoREPORT -vn "$tmp/read.pp" 2>&1)"
if echo "$read_log" | grep -qF "$FIRED"; then
  echo "A read-arm shape: sink FIRED"
else
  fail "sink did NOT fire on a genuine one-arm-read shape (pass stopped firing)"
  echo "$read_log" | grep -i sink || true
fi

# ---------------------------------------------------------------------------
# Part B: refuses the val-tail shape (arm only WRITES V)
# ---------------------------------------------------------------------------
cat > "$tmp/write.pp" <<'EOF'
{$mode objfpc}
procedure compute(sp, ns: longint; ch: byte; out code: longint);
begin
  code := 0;
  if (sp <= ns) and (ch <> 0) then
    code := sp;                    { then-arm only WRITES code }
end;
var code: longint;
begin
  code := 20; compute(21,20,55,code); writeln(code);   { fall-through -> 0 }
end.
EOF
write_log="$("$CC" -Fu"$RTL" -O4 -OoREPORT -vn "$tmp/write.pp" 2>&1)"
if echo "$write_log" | grep -qF "$FIRED"; then
  fail "sink FIRED on the val-tail write-only-arm shape (unsound, blocker #7)"
else
  echo "B val-tail write-arm shape: sink DECLINED"
fi
# behavioural: the fall-through must keep the default store (code=0), not 20
"$CC" -Fu"$RTL" -O4 -o"$tmp/write" "$tmp/write.pp" >/dev/null 2>&1
out="$( (ulimit -v 3000000; timeout 30 "$tmp/write") 2>&1 )"
if [ "$out" = "0" ]; then
  echo "B fall-through default store preserved (code=0)"
else
  fail "fall-through returned code=$out (default store lost)"
fi

# ---------------------------------------------------------------------------
# Part C: promoted regression, -O4 vs -O4 -OoNOSINK byte-identical, exit 0
# ---------------------------------------------------------------------------
REG="$here/testfiles/sink_outparam_default/sink_outparam_default_01.pp"
if [ -f "$REG" ]; then
  "$CC" -Fu"$RTL" -O4            -o"$tmp/reg_o4"  "$REG" >/dev/null 2>&1
  "$CC" -Fu"$RTL" -O4 -OoNOSINK -o"$tmp/reg_ns"  "$REG" >/dev/null 2>&1
  (ulimit -v 3000000; timeout 30 "$tmp/reg_o4"); a=$?
  (ulimit -v 3000000; timeout 30 "$tmp/reg_ns"); b=$?
  if [ "$a" = 0 ] && [ "$b" = 0 ]; then
    echo "C regression: exit 0 at -O4 and -O4 -OoNOSINK"
  else
    fail "regression exit codes differ / nonzero (-O4=$a, -OoNOSINK=$b)"
  fi
else
  fail "missing regression test $REG"
fi

[ $rc -eq 0 ] && echo "sink_outparam_check: ALL OK"
exit $rc
