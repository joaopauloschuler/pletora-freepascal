#!/usr/bin/env bash
#
# Element-wise vectorizer: object-field array-base recognition assertions.
#
# The fork's loop recognizers used a simple-var rule (rangeelim_simple_var): an
# array base had to be a stable, non-address-taken LOCAL or PARAMETER.  That
# rejected  Self.FData -style object-field dynamic-array bases (as in neural-api
# TNNetVolume.FData), so no loop optimization fired inside real methods.
#
# The element-wise vectorizer (-OoVECTORIZE, an -O4 default) now also accepts an
# array base of the form  <stable-ref>.<field>  -- Self, or a simple non-aliased
# local/value-param object|class reference -- by PRE-HOISTING the invariant field
# load into a fresh non-managed preheader snapshot (a borrowed data pointer) and
# repointing every in-loop access at it, then running the existing simple-var
# recognizer.  It is conservative: it declines when the body makes any call (a
# method could reassign the field) or when the reference itself is reassigned.
#
# Asserts:
#   1. A class-method element-wise loop over a dynamic-array FIELD base vectorizes
#      (packed SSE ops present; -OoREPORT emits the vectorize remark).
#   2. A reduction (dot product) over field bases vectorizes under fast-math.
#   3. It DECLINES (no packed body) when the loop body makes a call.
#   4. It DECLINES when the loop body also reassigns the field (store through Self).
#   5. Bit-exact runtime: the fixture's checksum is identical with the optimizer
#      (-O4 -OoVECTORIZE -OoFASTMATH) and without it (-O-).
#
# Usage: unleashed/tests/fieldbase_vect_check.sh [path-to-ppcx64]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- element-wise store over a class-FIELD dynamic-array base (the only loop) ---
cat > "$tmp/fe.pp" <<'EOF'
program fe;
{$mode objfpc}{$H+}{$Q-}{$R-}
type TV = class FA, FB, FC : array of single; procedure Go; end;
procedure TV.Go;
var i: longint;
begin
  for i:=0 to High(FA) do FA[i] := FB[i] + FC[i];
end;
var v: TV;
begin v:=TV.Create; SetLength(v.FA,64); SetLength(v.FB,64); SetLength(v.FC,64); v.Go; end.
EOF

# --- reduction (dot product) over field bases ---
cat > "$tmp/fd.pp" <<'EOF'
program fd;
{$mode objfpc}{$H+}{$Q-}{$R-}
type TV = class FB, FC : array of single; function Dot: single; end;
function TV.Dot: single;
var i: longint; s: single;
begin s:=0; for i:=0 to High(FB) do s:=s+FB[i]*FC[i]; Dot:=s; end;
var v: TV;
begin v:=TV.Create; SetLength(v.FB,64); SetLength(v.FC,64); Writeln(v.Dot:0:3); end.
EOF

# --- field base but the body makes a call: must DECLINE (field could be reassigned) ---
cat > "$tmp/fc.pp" <<'EOF'
program fc;
{$mode objfpc}{$H+}{$Q-}{$R-}
var g: longint;
procedure Bump; begin inc(g); end;
type TV = class FA, FB, FC : array of single; procedure Go; end;
procedure TV.Go;
var i: longint;
begin
  for i:=0 to High(FA) do begin FA[i] := FB[i] + FC[i]; Bump; end;
end;
var v: TV;
begin v:=TV.Create; SetLength(v.FA,64); SetLength(v.FB,64); SetLength(v.FC,64); v.Go; end.
EOF

# --- field base but the body reassigns the field (store through Self): must DECLINE ---
cat > "$tmp/fs.pp" <<'EOF'
program fs;
{$mode objfpc}{$H+}{$Q-}{$R-}
type TV = class FA, FB, FC : array of single; procedure Go; end;
procedure TV.Go;
var i: longint;
begin
  for i:=0 to High(FA) do begin FA[i] := FB[i] + FC[i]; FB := FC; end;
end;
var v: TV;
begin v:=TV.Create; SetLength(v.FA,64); SetLength(v.FB,64); SetLength(v.FC,64); v.Go; end.
EOF

compile() { # $1=src ; rest=flags -> writes ${src%.pp}.s in $tmp, report to .rep
  local src="$1"; shift
  ( cd "$tmp" && "$CC" -Fu"$RTL" "$@" -al -s "$src" > "${src%.pp}.rep" 2>&1 )
}

# a "packed body" = at least one packed SSE arithmetic/move op over xmm/ymm
packed() { grep -cE '(add|mul|sub)ps[[:space:]]|movups[[:space:]]' "$1" || true; }

rc=0

# ---- 1. element-wise field-base store vectorizes ----
compile fe.pp -O4 -OoVECTORIZE -OoREPORT
p=$(packed "$tmp/fe.s")
r=$(grep -cE 'vectorize: loop vectorized' "$tmp/fe.rep" || true)
echo "field elementwise : packed=$p report=$r (both must be >=1)"
[ "$p" -ge 1 ] || { echo "FAIL: no packed body for a class-field element-wise loop"; rc=1; }
[ "$r" -ge 1 ] || { echo "FAIL: -OoREPORT did not report the field-base loop vectorized"; rc=1; }

# ---- 2. reduction (dot) over field bases vectorizes under fast-math ----
compile fd.pp -O4 -OoVECTORIZE -OoFASTMATH -OoREPORT
p=$(packed "$tmp/fd.s")
r=$(grep -cE 'vectorize: reduction loop vectorized' "$tmp/fd.rep" || true)
echo "field reduction   : packed=$p report=$r (both must be >=1)"
[ "$p" -ge 1 ] || { echo "FAIL: no packed body for a class-field reduction loop"; rc=1; }
[ "$r" -ge 1 ] || { echo "FAIL: -OoREPORT did not report the field-base reduction vectorized"; rc=1; }

# ---- 3. body makes a call: must DECLINE (no packed body) ----
compile fc.pp -O4 -OoVECTORIZE
p=$(packed "$tmp/fc.s")
echo "field + call      : packed=$p (must be 0)"
[ "$p" -eq 0 ] || { echo "FAIL: vectorized a field-base loop whose body makes a call"; rc=1; }

# ---- 4. body reassigns the field: must DECLINE (no packed body) ----
compile fs.pp -O4 -OoVECTORIZE
p=$(packed "$tmp/fs.s")
echo "field reassigned  : packed=$p (must be 0)"
[ "$p" -eq 0 ] || { echo "FAIL: vectorized a field-base loop that reassigns the field"; rc=1; }

# ---- 5. bit-exact runtime: optimized checksum == -O- checksum ----
fx="$here/testfiles/fieldbase/fieldbase_runtime.pp"
( cd "$tmp" && "$CC" -Fu"$RTL" -O4 -OoVECTORIZE -OoFASTMATH "$fx" -o"$tmp/fr_o4" >/dev/null 2>&1 )
( cd "$tmp" && "$CC" -Fu"$RTL" -O- "$fx" -o"$tmp/fr_o0" >/dev/null 2>&1 )
o4=$("$tmp/fr_o4"); o0=$("$tmp/fr_o0")
echo "runtime O4=$o4  O-=$o0"
[ "$o4" = "$o0" ] || { echo "FAIL: field-base vectorized checksum differs from -O- (miscompile)"; rc=1; }

if [ "$rc" -eq 0 ]; then
  echo "fieldbase_vect_check: PASS"
else
  echo "fieldbase_vect_check: FAIL"
fi
exit "$rc"
