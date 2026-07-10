#!/usr/bin/env bash
# Codegen + remark assertions for -OoDEVIRT (provable-receiver devirtualization).
#
# Proves the transform actually rewrites indirect VMT dispatch into a direct
# call at a provable site, keeps the indirect dispatch when the switch is off
# and at non-provable sites, and emits the exact -Ooreport remark lines.
#
# Usage: unleashed/tests/devirt_check.sh [path-to-ppcx64]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# One program with a provable site (Prov), a two-class non-provable site
# (Poly), and a var-parameter rebind non-provable site (Rebound).
cat > "$tmp/d.pp" <<'EOF'
program d;
{$mode objfpc}{$H+}
type
  TBase = class
    procedure Go; virtual;
  end;
  TFoo = class(TBase)
    procedure Go; override;
  end;
  TBar = class(TBase)
    procedure Go; override;
  end;
procedure TBase.Go; begin end;
procedure TFoo.Go; begin Writeln('f'); end;
procedure TBar.Go; begin Writeln('b'); end;

procedure Prov;              { provable: constructed TFoo, never rebound }
var b: TBase;
begin
  b := TFoo.Create;
  b.Go;
  b.Free;
end;

procedure Poly(useFoo: boolean);   { two classes reach the call -> not provable }
var b: TBase;
begin
  if useFoo then b := TFoo.Create else b := TBar.Create;
  b.Go;
  b.Free;
end;

procedure Rebind(var b: TBase);
begin b := TBar.Create; end;

procedure Rebound;          { rebound through a var param -> not provable }
var b: TBase;
begin
  b := TFoo.Create;
  Rebind(b);
  b.Go;
  b.Free;
end;

begin
  Prov; Poly(true); Rebound;
end.
EOF

mkdir -p "$tmp/on" "$tmp/off"
cp "$tmp/d.pp" "$tmp/on/"; cp "$tmp/d.pp" "$tmp/off/"
( cd "$tmp/on"  && "$CC" -Fu"$RTL" -O2 -OoDEVIRT -al -s d.pp >/dev/null 2>&1 )
( cd "$tmp/off" && "$CC" -Fu"$RTL" -O2           -al -s d.pp >/dev/null 2>&1 )

body() { sed -n "/^P\$D_\$\$_$1:/,/^\.Le[0-9]/p" "$2"; }

# Provable site under -OoDEVIRT: a DIRECT call to TFoo.Go, no indirect VMT load.
prov_direct=$(body PROV "$tmp/on/d.s"  | grep -cE 'call[[:space:]]+P\$D\$_\$TFOO_\$__\$\$_GO' || true)
prov_indir=$( body PROV "$tmp/on/d.s"  | grep -cE 'call[[:space:]]+\*[0-9]+\(' || true)
# Same site WITHOUT the switch: indirect VMT dispatch retained.
prov_off_indir=$(body PROV "$tmp/off/d.s" | grep -cE 'call[[:space:]]+\*[0-9]+\(' || true)
prov_off_direct=$(body PROV "$tmp/off/d.s" | grep -cE 'call[[:space:]]+P\$D\$_\$TFOO_\$__\$\$_GO' || true)
# Non-provable sites under -OoDEVIRT: indirect dispatch retained.
poly_indir=$( body 'POLY\$BOOLEAN' "$tmp/on/d.s" | grep -cE 'call[[:space:]]+\*[0-9]+\(' || true)
reb_indir=$(  body REBOUND         "$tmp/on/d.s" | grep -cE 'call[[:space:]]+\*[0-9]+\(' || true)

echo "PROV  on : direct=$prov_direct (expect 1) indirect=$prov_indir (expect 0)"
echo "PROV  off: direct=$prov_off_direct (expect 0) indirect=$prov_off_indir (expect 1)"
echo "POLY  on : indirect=$poly_indir (expect 1)"
echo "REBND on : indirect=$reb_indir (expect 1)"

# Exact remark lines from -Ooreport.
rem="$("$CC" -Fu"$RTL" -O2 -OoDEVIRT -OoREPORT "$tmp/d.pp" -o"$tmp/dbin" 2>&1 | grep 'devirt:' || true)"
applied=$(  printf '%s\n' "$rem" | grep -cF 'devirt: call to TFoo.Go devirtualized (receiver constructed as TFoo)' || true)
miss_poly=$(printf '%s\n' "$rem" | grep -cF 'not devirtualized (receiver reassigned / address-taken / passed by reference)' || true)
echo "REMARK applied(TFoo.Go)=$applied (expect 1)  missed(reassigned/byref)=$miss_poly (expect >=2)"

rc=0
[ "$prov_direct"     -eq 1 ] || { echo "FAIL: provable site not turned into a direct call under -OoDEVIRT"; rc=1; }
[ "$prov_indir"      -eq 0 ] || { echo "FAIL: provable site still has an indirect VMT call under -OoDEVIRT"; rc=1; }
[ "$prov_off_indir"  -eq 1 ] || { echo "FAIL: provable site is not an indirect VMT call without the switch"; rc=1; }
[ "$prov_off_direct" -eq 0 ] || { echo "FAIL: a direct call to the override appeared without the switch"; rc=1; }
[ "$poly_indir"      -eq 1 ] || { echo "FAIL: two-class non-provable site was devirtualized"; rc=1; }
[ "$reb_indir"       -eq 1 ] || { echo "FAIL: var-param-rebound non-provable site was devirtualized"; rc=1; }
[ "$applied"         -eq 1 ] || { echo "FAIL: expected exact applied remark not emitted"; rc=1; }
[ "$miss_poly"       -ge 2 ] || { echo "FAIL: expected missed remarks (non-provable sites) not emitted"; rc=1; }

[ "$rc" -eq 0 ] && echo "PASS: provable site devirtualized to a direct call; switch-off and non-provable sites keep indirect VMT dispatch; remarks exact"
exit "$rc"
