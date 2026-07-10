#!/usr/bin/env bash
# Codegen assertion for the -OoDEVIRT inliner integration (follow-up (a)).
#
# A virtual method can never carry po_inline (it is mutually exclusive with
# po_virtualmethod), so the ordinary/auto inliner never touches a virtual call.
# Under -OoDEVIRT the body of a small virtual method is instead RETAINED as
# inlining info (without po_inline), and a call proven to reach exactly one
# override is rebound and expanded by the ordinary inliner in the same routine.
#
# This proves that a devirtualized call to a small inlineable PROCEDURE body is
# fully inlined -- no call to the target and no indirect VMT dispatch at all --
# when inlining is on; that a non-provable (two-class) site keeps its indirect
# VMT dispatch even with the switch; and that without the switch the provable
# site keeps its indirect VMT dispatch. (Function-result targets are out of the
# inline path by design and keep the direct-call devirtualization.)
#
# Usage: unleashed/tests/devirt_inline_check.sh [path-to-ppcx64]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Prov: a provable (locally constructed, never rebound) receiver calling a small
# virtual PROCEDURE.  Poly: two classes reach the call -> not provable.
cat > "$tmp/d.pp" <<'EOF'
program d;
{$mode objfpc}{$H+}
var sink: int64;
type
  TBase = class
    procedure Step(x: longint); virtual;
  end;
  TInc = class(TBase)
    procedure Step(x: longint); override;
  end;
  TDbl = class(TBase)
    procedure Step(x: longint); override;
  end;
procedure TBase.Step(x: longint); begin sink:=sink+x; end;
procedure TInc.Step(x: longint);  begin sink:=sink+x+1; end;
procedure TDbl.Step(x: longint);  begin sink:=sink+2*x; end;

procedure Prov;                 { provable: constructed TInc, never rebound }
var b: TBase; i: longint;
begin
  b := TInc.Create;
  for i := 1 to 10 do b.Step(i);
  b.Free;
end;

procedure Poly(useDbl: boolean); { two classes reach the call -> not provable }
var b: TBase; i: longint;
begin
  if useDbl then b := TDbl.Create else b := TInc.Create;
  for i := 1 to 10 do b.Step(i);
  b.Free;
end;

begin
  sink:=0; Prov; Poly(true); Poly(false);
end.
EOF

asm_prov() { sed -n '/^P\$D_\$\$_PROV:/,/^\.Le[0-9]/p' "$1"; }
asm_poly() { sed -n '/^P\$D_\$\$_POLY\$BOOLEAN:/,/^\.Le[0-9]/p' "$1"; }

# 1) inlining ON: the provable Step call is inlined -> no call to Step, no indirect.
"$CC" -Fu"$RTL" -O2 -OoDEVIRT -al -s "$tmp/d.pp" -o"$tmp/on" >/dev/null 2>&1
on_step=$(  asm_prov "$tmp/d.s" | grep -cE 'call[[:space:]]+.*_STEP'   || true)
on_indir=$( asm_prov "$tmp/d.s" | grep -cE 'call[[:space:]]+\*[0-9]+\(' || true)
# non-provable Poly site keeps indirect VMT dispatch even with the switch.
poly_indir=$(asm_poly "$tmp/d.s" | grep -cE 'call[[:space:]]+\*[0-9]+\(' || true)

# 2) switch OFF entirely: provable site keeps indirect VMT dispatch.
"$CC" -Fu"$RTL" -O2 -al -s "$tmp/d.pp" -o"$tmp/off" >/dev/null 2>&1
off_indir=$(asm_prov "$tmp/d.s" | grep -cE 'call[[:space:]]+\*[0-9]+\(' || true)

# exact remark from -Ooreport
rem="$("$CC" -Fu"$RTL" -O2 -OoDEVIRT -OoREPORT "$tmp/d.pp" -o"$tmp/dbin" 2>&1 | grep 'devirt:' || true)"
inlined=$(printf '%s\n' "$rem" | grep -cF 'devirtualized and inlined (receiver constructed as TInc)' || true)

echo "ON   : Step-call=$on_step (expect 0) indirect=$on_indir (expect 0)"
echo "POLY : indirect=$poly_indir (expect 1)"
echo "OFF  : indirect=$off_indir (expect 1)"
echo "REMARK inlined(TInc.Step)=$inlined (expect 1)"

# confirm runtime correctness under the switch (must not crash / must exit 0)
"$CC" -Fu"$RTL" -O2 -OoDEVIRT "$tmp/d.pp" -o"$tmp/run" >/dev/null 2>&1
( ulimit -v 3000000; timeout 60 "$tmp/run" ) ; runrc=$?

rc=0
[ "$on_step"    -eq 0 ] || { echo "FAIL: devirtualized provable site still calls the target (not inlined)"; rc=1; }
[ "$on_indir"   -eq 0 ] || { echo "FAIL: devirtualized provable site still has an indirect VMT call"; rc=1; }
[ "$poly_indir" -eq 1 ] || { echo "FAIL: non-provable site was devirtualized/inlined"; rc=1; }
[ "$off_indir"  -eq 1 ] || { echo "FAIL: without the switch, provable site is not an indirect VMT call"; rc=1; }
[ "$inlined"    -eq 1 ] || { echo "FAIL: expected 'devirtualized and inlined' remark not emitted"; rc=1; }
[ "$runrc"      -eq 0 ] || { echo "FAIL: inlined program did not run cleanly (rc=$runrc)"; rc=1; }

[ "$rc" -eq 0 ] && echo "PASS: devirtualized small procedure body fully inlined (no call, no indirect); non-provable and switch-off sites keep indirect VMT dispatch; remark exact; runs correctly"
exit "$rc"
