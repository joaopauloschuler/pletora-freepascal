#!/usr/bin/env bash
# Codegen + remark assertions for -OoIPACP (interprocedural constant propagation
# via call-site-driven function cloning).
#
# Proves that: two call families passing distinct compile-time constants create
# two distinct, uniquely-named out-of-line clones; repeated call sites with the
# same constant share ONE clone; the specialized calls target the clone symbols
# while the general body is retained (for the runtime-argument site); the
# constant is actually folded inside a clone (dead branch / folded loop bound);
# the exact -Ooreport remark lines are emitted; and NOTHING is cloned when the
# switch is off.
#
# Usage: unleashed/tests/ipacp_check.sh [path-to-ppcx64]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Scale(x, factor): factor is the specialized parameter. It gates an early
# `exit` (factor=0 -> a dead-branch-eliminable clone) and bounds a loop
# (constant loop bound in a clone). Two constant families (3 and 0) plus a
# runtime-argument site.
cat > "$tmp/p.pp" <<'EOF'
program p;
{$mode objfpc}{$H+}

function Scale(x, factor: longint): longint;
var i, s: longint;
begin
  s := 0;
  if factor = 0 then
    exit(0);
  for i := 1 to factor do
    s := s + x;
  Scale := s;
end;

function A(v: longint): longint;   { two calls, both factor=3 -> ONE clone }
begin
  A := Scale(v, 3) + Scale(v + 1, 3);
end;

function B(v: longint): longint;   { factor=0 -> a second, distinct clone }
begin
  B := Scale(v, 0);
end;

function C(v, f: longint): longint; { runtime factor -> general body kept }
begin
  C := Scale(v, f);
end;

begin
  Writeln(A(2) + B(9) + C(3, 4));
end.
EOF

mkdir -p "$tmp/on" "$tmp/off"
cp "$tmp/p.pp" "$tmp/on/"; cp "$tmp/p.pp" "$tmp/off/"
( cd "$tmp/on"  && "$CC" -Fu"$RTL" -O2 -OoIPACP -al -s p.pp >/dev/null 2>&1 )
( cd "$tmp/off" && "$CC" -Fu"$RTL" -O2           -al -s p.pp >/dev/null 2>&1 )

on="$tmp/on/p.s"
off="$tmp/off/p.s"

# 1. Distinct clone symbols exist and are unique under -OoIPACP.
clone_defs=$(grep -cE '^\.globl[[:space:]]+.*_SCALE\$LONGINT\$LONGINT\$\$LONGINT\$ipacp\$' "$on" || true)
clone_uniq=$(grep -oE '_SCALE\$LONGINT\$LONGINT\$\$LONGINT\$ipacp\$[A-Za-z0-9]+' "$on" | sort -u | wc -l | tr -d ' ')
# 2. No clones at all when the switch is off.
clone_off=$(grep -cE 'ipacp' "$off" || true)
# 3. The general Scale body is still emitted (retained for the runtime site):
#    its label appears, and it is not an ipacp clone label.
general=$(grep -cE '^P\$P_\$\$_SCALE\$LONGINT\$LONGINT\$\$LONGINT:$' "$on" || true)
# 4. The runtime-argument site C calls the GENERAL Scale (no ipacp suffix).
c_general=$(sed -n '/^P\$P_\$\$_C\$LONGINT\$LONGINT\$\$LONGINT:/,/^\.Le[0-9]/p' "$on" \
  | grep -cE 'call[[:space:]]+.*_SCALE\$LONGINT\$LONGINT\$\$LONGINT:?$' || true)
# 5. A and B call clone symbols (ipacp suffix).
a_clone=$(sed -n '/^P\$P_\$\$_A\$LONGINT\$\$LONGINT:/,/^\.Le[0-9]/p' "$on" \
  | grep -cE 'call[[:space:]]+.*ipacp\$' || true)
b_clone=$(sed -n '/^P\$P_\$\$_B\$LONGINT\$\$LONGINT:/,/^\.Le[0-9]/p' "$on" \
  | grep -cE 'call[[:space:]]+.*ipacp\$' || true)

echo "clones defined=$clone_defs unique=$clone_uniq (expect 2/2)"
echo "clones with switch off=$clone_off (expect 0)"
echo "general Scale retained=$general (expect 1)"
echo "C -> general Scale calls=$c_general (expect 1)"
echo "A -> clone calls=$a_clone (expect 2)   B -> clone calls=$b_clone (expect 1)"

# 6. The factor=0 clone is fully folded: its body just returns 0 (no loop, no
#    runtime comparison of factor).
zbody=$(awk '/\$ipacp\$p1v0:/{f=1} f{print} f&&/ret$/{exit}' "$on")
zero_folded=$(printf '%s\n' "$zbody" | grep -cE 'xor|movl[[:space:]]+\$0' || true)
zero_noloop=$(printf '%s\n' "$zbody" | grep -cE '\bcall\b|jle|jl[[:space:]]|jg' || true)
echo "factor=0 clone: zeroed=$zero_folded (expect >=1) loop/branch=$zero_noloop (expect 0)"

# 7. Exact -Ooreport remarks: applied for factor=3 (twice, both A sites) and
#    factor=0 (once, B); no remark for the runtime site.
rem="$("$CC" -Fu"$RTL" -O2 -OoIPACP -OoREPORT "$tmp/p.pp" -o"$tmp/pbin" 2>&1 | grep 'ipacp:' || true)"
r3=$(printf '%s\n' "$rem" | grep -cF 'ipacp: call to Scale specialized for factor=3' || true)
r0=$(printf '%s\n' "$rem" | grep -cF 'ipacp: call to Scale specialized for factor=0' || true)
echo "remarks: factor=3 x$r3 (expect 2)  factor=0 x$r0 (expect 1)"

rc=0
[ "$clone_defs" -eq 2 ] || { echo "FAIL: expected exactly 2 clone symbol definitions"; rc=1; }
[ "$clone_uniq" -eq 2 ] || { echo "FAIL: clone symbols are not the 2 expected unique names"; rc=1; }
[ "$clone_off"  -eq 0 ] || { echo "FAIL: clones were emitted without -OoIPACP"; rc=1; }
[ "$general"    -eq 1 ] || { echo "FAIL: general Scale body not retained"; rc=1; }
[ "$c_general"  -ge 1 ] || { echo "FAIL: runtime-argument site does not call the general body"; rc=1; }
[ "$a_clone"    -eq 2 ] || { echo "FAIL: A's two factor=3 sites do not both call the shared clone"; rc=1; }
[ "$b_clone"    -eq 1 ] || { echo "FAIL: B's factor=0 site does not call its clone"; rc=1; }
[ "$zero_folded" -ge 1 ] || { echo "FAIL: factor=0 clone did not fold to a zero result"; rc=1; }
[ "$zero_noloop" -eq 0 ] || { echo "FAIL: factor=0 clone still has a loop/branch (constant not folded)"; rc=1; }
[ "$r3" -eq 2 ] || { echo "FAIL: expected two factor=3 applied remarks"; rc=1; }
[ "$r0" -eq 1 ] || { echo "FAIL: expected one factor=0 applied remark"; rc=1; }

[ "$rc" -eq 0 ] && echo "PASS: two distinct shared clones with folded constants; general body kept for the runtime site; no clones without the switch; remarks exact"
exit "$rc"
