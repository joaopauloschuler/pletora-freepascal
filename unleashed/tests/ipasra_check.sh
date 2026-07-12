#!/usr/bin/env bash
# Codegen + runtime assertions for -OoIPASRA (interprocedural scalar replacement
# of aggregates, part (b) of the gcc -fipa-sra port; see compiler/optipasra.pas).
#
# -OoIPASRA splits a `const`/`constref` RECORD parameter whose fields are only
# READ in the callee into individual by-value SCALAR parameters.  A single-pass
# fork cannot rewrite an already-compiled callee's signature, so (exactly like
# -OoIPACP) it CLONES: an eligible routine's pre-firstpass body is stashed, and a
# later caller that passes a side-effect-free record actual for every splittable
# parameter gets one out-of-line clone whose signature has the record param
# replaced by N scalar params (one per read field) and whose body reads those
# params DIRECTLY (the memory indirection is gone); the call is rebuilt to pass
# `rec.f1 .. rec.fN`.
#
# Assertions:
#   * a two-field const-record helper called in a loop gets a $ipasra clone whose
#     fields are register-resident scalar params (the `$sra$...located in
#     register` comments in -al output), only with -OoIPASRA;
#   * refusal cases emit NO ipasra remark: a by-VALUE (non-const) record param, a
#     WHOLE-record address `@r`, a WHOLE-record pass-on to another routine, a
#     VIRTUAL-method callee, a record with >4 read fields, a record with a
#     MANAGED field;
#   * the switch is off by default;
#   * the bit-exact runtime fixture testfiles/optipasra/ipasra_exact_01.pp
#     produces byte-identical output (and side-effect counter) with and without
#     the switch.
#
# Usage: unleashed/tests/ipasra_check.sh [path-to-ppcx64]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

rc=0

ipasra_remarks() { grep -cE 'ipasra: call to' "$1" || true; }
sra_regvars()    { grep -cE '\$sra\$.*located in register' "$1" || true; }

# ---- 1: two-field const-record helper in a loop -> split clone ---------------
cat > "$tmp/hit.pp" <<'EOF'
program hit;
{$mode objfpc}
type TPair = record x, y: longint; end;
function ev(const p: TPair; k: longint): longint; noinline;
begin ev := p.x * 7 + p.y - k; end;
var p: TPair; i, s: longint;
begin p.x := 3; p.y := 5; s := 0;
  for i := 1 to 8 do s := s + ev(p, i);
  writeln(s);
end.
EOF
"$CC" -Fu"$RTL" -O2 -OoREPORT -al -s "$tmp/hit.pp" -FE"$tmp" >"$tmp/hit_off.log" 2>&1
off_rem=$(ipasra_remarks "$tmp/hit_off.log")
"$CC" -Fu"$RTL" -O2 -OoIPASRA -OoREPORT -al -s "$tmp/hit.pp" -FE"$tmp" >"$tmp/hit_on.log" 2>&1
on_rem=$(ipasra_remarks "$tmp/hit_on.log")
on_regs=$(sra_regvars "$tmp/hit.s")
on_sym=$(grep -cE '\$ipasra' "$tmp/hit.s" || true)
echo "two-field const-record helper: remarks off=$off_rem on=$on_rem ; clone \$sra register vars=$on_regs ; \$ipasra symbol lines=$on_sym"
[ "$off_rem" -eq 0 ] || { echo "FAIL: -OoIPASRA fired without the switch"; rc=1; }
[ "$on_rem"  -ge 1 ] || { echo "FAIL: a splittable const-record call was not rewritten"; rc=1; }
[ "$on_regs" -ge 2 ] || { echo "FAIL: split fields did not become register-resident scalar params"; rc=1; }
[ "$on_sym"  -ge 1 ] || { echo "FAIL: no split-parameter clone symbol emitted"; rc=1; }

# ---- 2: refusal cases emit NO ipasra remark ----------------------------------
check_refused() {
  local name="$1" src="$2"
  printf '%s' "$src" > "$tmp/$name.pp"
  "$CC" -Fu"$RTL" -O2 -OoIPASRA -OoREPORT -s "$tmp/$name.pp" -FE"$tmp" >"$tmp/$name.log" 2>&1 || {
    echo "FAIL: $name did not compile"; rc=1; return; }
  local n; n=$(ipasra_remarks "$tmp/$name.log")
  echo "refusal[$name]: ipasra remarks=$n (expect 0)"
  [ "$n" -eq 0 ] || { echo "FAIL: $name was wrongly split"; rc=1; }
}

check_refused byvalue '
program byvalue;
{$mode objfpc}
type TPair = record x, y: longint; end;
function ev(p: TPair; k: longint): longint; noinline;   { by-VALUE record, refused }
begin ev := p.x + p.y - k; end;
var p: TPair; i, s: longint;
begin p.x := 1; p.y := 2; s := 0;
  for i := 1 to 4 do s := s + ev(p, i);
  writeln(s);
end.'

check_refused wholeaddr '
program wholeaddr;
{$mode objfpc}
type TPair = record x, y: longint; end;
function ev(const p: TPair): longint; noinline;
var q: ^TPair;
begin q := @p; ev := q^.x + p.y; end;                    { WHOLE-record @p, refused }
var p: TPair; i, s: longint;
begin p.x := 1; p.y := 2; s := 0;
  for i := 1 to 4 do s := s + ev(p);
  writeln(s);
end.'

check_refused passon '
program passon;
{$mode objfpc}
type TPair = record x, y: longint; end;
function sink(const p: TPair): longint; noinline;        { reads WHOLE p via @, refused }
var q: ^TPair;
begin q := @p; sink := q^.x - q^.y; end;
function ev(const p: TPair): longint; noinline;
begin ev := sink(p) + p.x; end;                          { passes WHOLE p on, refused }
var p: TPair; i, s: longint;
begin p.x := 1; p.y := 2; s := 0;
  for i := 1 to 4 do s := s + ev(p);
  writeln(s);
end.'

check_refused virtualm '
program virtualm;
{$mode objfpc}
type TPair = record x, y: longint; end;
type TC = class function vm(const p: TPair): longint; virtual; end;
function TC.vm(const p: TPair): longint; begin vm := p.x + p.y; end;
var c: TC; p: TPair; i, s: longint;
begin c := TC.create; p.x := 1; p.y := 2; s := 0;
  for i := 1 to 4 do s := s + c.vm(p);
  writeln(s); c.free;
end.'

check_refused toobig '
program toobig;
{$mode objfpc}
type TBig = record a, b, c, d, e: longint; end;
function ev(const r: TBig): longint; noinline;           { >4 read fields, refused }
begin ev := r.a + r.b + r.c + r.d + r.e; end;
var r: TBig; i, s: longint;
begin r.a:=1;r.b:=2;r.c:=3;r.d:=4;r.e:=5; s := 0;
  for i := 1 to 4 do s := s + ev(r);
  writeln(s);
end.'

check_refused managed '
program managed;
{$mode objfpc}
type TM = record arr: array of longint; a: longint; end; { arr is a managed dynarray }
function ev(const r: TM): longint; noinline;             { managed field read, refused }
begin ev := length(r.arr) + r.a; end;
var r: TM; i, s: longint;
begin setlength(r.arr, 2); r.a := 3; s := 0;
  for i := 1 to 4 do s := s + ev(r);
  writeln(s);
end.'

# ---- 3: bit-exact runtime fixture --------------------------------------------
fix="$root/unleashed/tests/testfiles/optipasra/ipasra_exact_01.pp"
"$CC" -Fu"$RTL" -O4 "$fix" -FE"$tmp" -o"$tmp/fix_off" >/dev/null 2>&1
"$CC" -Fu"$RTL" -O4 -OoIPASRA -OoREPORT "$fix" -FE"$tmp" -o"$tmp/fix_on" >"$tmp/fix_on.log" 2>&1
fix_rem=$(ipasra_remarks "$tmp/fix_on.log")
out_off="$("$tmp/fix_off")"
out_on="$("$tmp/fix_on")"
echo "bit-exact fixture: ipasra remarks on=$fix_rem (expect >=1)"
echo "  off: $(echo "$out_off" | tr '\n' '|')"
echo "  on : $(echo "$out_on"  | tr '\n' '|')"
[ "$fix_rem" -ge 1 ] || { echo "FAIL: fixture did not exercise the split path"; rc=1; }
[ "$out_off" = "$out_on" ] || { echo "FAIL: -OoIPASRA changed observable output"; rc=1; }

if [ "$rc" -eq 0 ]; then echo "ipasra_check: PASS"; else echo "ipasra_check: FAIL"; fi
exit "$rc"
