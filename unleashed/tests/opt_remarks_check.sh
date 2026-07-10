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

[ "$rc" -eq 0 ] && echo "PASS: -Ooreport emits applied+missed remarks, silent when off, codegen unchanged"
exit "$rc"
