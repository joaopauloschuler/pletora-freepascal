#!/usr/bin/env bash
# Codegen assertion for the -OoAPPROXTRANS vectorized approximate-transcendental
# pass: an element-wise single-precision activation loop whose body is
# exp(b[i]) / tanh(b[i]) / 1/(1+exp(-b[i])) is lowered to an inline packed
# Cephes-style expf (range reduction cvtps2dq + a degree-5 polynomial + a 2^n
# exponent-field build) instead of a per-element scalar fpc_exp_real / math tanh
# call the loop vectorizer cannot widen across.
#
# The discriminating fingerprint of the inline packed path is CVTPS2DQ (the
# packed round-to-int of the range reduction) together with a run of packed
# MULPS (the polynomial) -- neither is emitted by the scalar libm path.  So:
#
#   * switch ON  : the vector loop body contains cvtps2dq + several mulps
#                  (the scalar fpc_exp_real / tanh call now only survives in the
#                  <VL scalar remainder tail, by design -- documented contract);
#   * switch OFF : NO cvtps2dq at all, and the scalar call is the whole loop;
#   * indirect shapes (non-unit index, double arrays) : NOT vectorized even with
#     the switch on -- no cvtps2dq.
#
# The bundled byte-based %CHECKBIN_* directive cannot match instruction
# mnemonics, so we inspect the emitted assembly (-al -s) instead.
#
# Usage: unleashed/tests/approxtrans_check.sh [path-to-ppcx64]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# exp / sigmoid / tanh activation kernels over simple non-aliased single arrays.
cat > "$tmp/kexp.pp" <<'EOF'
program kexp;
{$mode objfpc}{$H+}
type TS = array of single;
procedure act(a,b: TS);
var i: longint;
begin for i:=0 to high(a) do a[i]:=exp(b[i]); end;
var a,b: TS;
begin SetLength(a,64); SetLength(b,64); act(a,b); Writeln(a[0]:0:3); end.
EOF

cat > "$tmp/ksig.pp" <<'EOF'
program ksig;
{$mode objfpc}{$H+}
type TS = array of single;
procedure act(a,b: TS);
var i: longint;
begin for i:=0 to high(a) do a[i]:=1/(1+exp(-b[i])); end;
var a,b: TS;
begin SetLength(a,64); SetLength(b,64); act(a,b); Writeln(a[0]:0:3); end.
EOF

cat > "$tmp/ktanh.pp" <<'EOF'
program ktanh;
{$mode objfpc}{$H+}
uses math;
type TS = array of single;
procedure act(a,b: TS);
var i: longint;
begin for i:=0 to high(a) do a[i]:=tanh(b[i]); end;
var a,b: TS;
begin SetLength(a,64); SetLength(b,64); act(a,b); Writeln(a[0]:0:3); end.
EOF

# indirect shape: shifted index (b[i+1]) is not element-wise -> must NOT fire
cat > "$tmp/kidx.pp" <<'EOF'
program kidx;
{$mode objfpc}{$H+}
type TS = array of single;
procedure act(a,b: TS);
var i: longint;
begin for i:=0 to high(a)-1 do a[i]:=exp(b[i+1]); end;
var a,b: TS;
begin SetLength(a,64); SetLength(b,64); act(a,b); Writeln(a[0]:0:3); end.
EOF

# double arrays: approximate transcendental path is single-only -> must NOT fire
cat > "$tmp/kdbl.pp" <<'EOF'
program kdbl;
{$mode objfpc}{$H+}
type TD = array of double;
procedure act(a,b: TD);
var i: longint;
begin for i:=0 to high(a) do a[i]:=exp(b[i]); end;
var a,b: TD;
begin SetLength(a,64); SetLength(b,64); act(a,b); Writeln(a[0]:0:3); end.
EOF

compile() { # $1=src  $2..=flags
  local src="$1"; shift
  ( cd "$tmp" && "$CC" -Fu"$RTL" "$@" -al -s "$src" >/dev/null 2>&1 )
}

cnt() { grep -cE "$1" "$2" || true; }

rc=0

# ---- exp: ON vectorizes, OFF stays scalar ----
compile kexp.pp -O4 -OoAPPROXTRANS -Cfsse64
on="$tmp/kexp.s"
on_cvt=$(cnt 'cvtps2dq' "$on"); on_mul=$(cnt '(^|[^v])mulps' "$on")
echo "exp     ON  : cvtps2dq=$on_cvt (>=1)  mulps=$on_mul (>=4, polynomial)"
[ "$on_cvt" -ge 1 ] || { echo "FAIL: exp not vectorized with -OoAPPROXTRANS (no cvtps2dq)"; rc=1; }
[ "$on_mul" -ge 4 ] || { echo "FAIL: exp polynomial absent (mulps<4)"; rc=1; }

compile kexp.pp -O4 -Cfsse64
off="$tmp/kexp.s"
off_cvt=$(cnt 'cvtps2dq' "$off"); off_call=$(grep -ciE 'call[[:space:]]+fpc_exp_real' "$off" || true)
echo "exp     OFF : cvtps2dq=$off_cvt (must be 0)  fpc_exp_real-call=$off_call (>=1)"
[ "$off_cvt" -eq 0 ]  || { echo "FAIL: inline packed expf emitted without -OoAPPROXTRANS"; rc=1; }
[ "$off_call" -ge 1 ] || { echo "FAIL: scalar fpc_exp_real call missing with switch off"; rc=1; }

# ---- sigmoid: ON vectorizes (expf + a packed reciprocal divps) ----
compile ksig.pp -O4 -OoAPPROXTRANS -Cfsse64
sig="$tmp/ksig.s"
sig_cvt=$(cnt 'cvtps2dq' "$sig"); sig_div=$(cnt '(^|[^v])divps' "$sig")
echo "sigmoid ON  : cvtps2dq=$sig_cvt (>=1)  divps=$sig_div (>=1, 1/(1+e))"
[ "$sig_cvt" -ge 1 ] || { echo "FAIL: sigmoid not vectorized with -OoAPPROXTRANS"; rc=1; }
[ "$sig_div" -ge 1 ] || { echo "FAIL: sigmoid packed reciprocal (divps) absent"; rc=1; }

compile ksig.pp -O4 -Cfsse64
[ "$(cnt 'cvtps2dq' "$tmp/ksig.s")" -eq 0 ] || { echo "FAIL: sigmoid inline packed path without switch"; rc=1; }

# ---- tanh: ON vectorizes; OFF keeps the math-unit tanh call ----
compile ktanh.pp -O4 -OoAPPROXTRANS -Cfsse64
tsig="$tmp/ktanh.s"
tanh_cvt=$(cnt 'cvtps2dq' "$tsig")
echo "tanh    ON  : cvtps2dq=$tanh_cvt (>=1)"
[ "$tanh_cvt" -ge 1 ] || { echo "FAIL: tanh not vectorized with -OoAPPROXTRANS"; rc=1; }

compile ktanh.pp -O4 -Cfsse64
toff="$tmp/ktanh.s"
tanh_off_cvt=$(cnt 'cvtps2dq' "$toff"); tanh_off_call=$(cnt 'call[[:space:]]+.*TANH' "$toff")
echo "tanh    OFF : cvtps2dq=$tanh_off_cvt (must be 0)  math-tanh-call=$tanh_off_call (>=1)"
[ "$tanh_off_cvt" -eq 0 ]  || { echo "FAIL: inline packed tanh emitted without -OoAPPROXTRANS"; rc=1; }
[ "$tanh_off_call" -ge 1 ] || { echo "FAIL: scalar math tanh call missing with switch off"; rc=1; }

# ---- indirect / double shapes must NOT fire even with the switch on ----
compile kidx.pp -O4 -OoAPPROXTRANS -Cfsse64
[ "$(cnt 'cvtps2dq' "$tmp/kidx.s")" -eq 0 ] || { echo "FAIL: shifted-index exp(b[i+1]) wrongly vectorized"; rc=1; }
echo "exp idx ON  : cvtps2dq=0 (shifted index correctly declined)"

compile kdbl.pp -O4 -OoAPPROXTRANS -Cfsse64
[ "$(cnt 'cvtps2dq' "$tmp/kdbl.s")" -eq 0 ] || { echo "FAIL: double-array exp wrongly vectorized (single-only path)"; rc=1; }
echo "exp dbl ON  : cvtps2dq=0 (double array correctly declined)"

# ---- AVX2 256-bit ymm path (-OoVECT256 on an AVX2 fputype) ----
# The inline packed expf widens to 256-bit ymm ONLY when -OoVECT256 is requested
# AND the fputype has an AVX2 unit: the 2^n exponent build (vpaddd + vpslld) is an
# AVX2 integer op at 256-bit width. On an AVX2 fputype the whole expf body runs on
# ymm registers (vcvtps2dq/vmulps/vpaddd all %ymm); on an AVX-ONLY fputype the
# transcendental stays 128-bit (no vpaddd %ymm) even though ordinary float loops
# still widen to ymm; on SSE there is no ymm at all.
compile kexp.pp -O4 -OoAPPROXTRANS -OoVECT256 -Cfavx2
y="$tmp/kexp.s"
y_ymm=$(cnt 'vcvtps2dq[[:space:]]+%ymm' "$y")
y_vpaddd=$(cnt 'vpaddd[[:space:]]+.*%ymm' "$y")
y_vpslld=$(cnt 'vpslld[[:space:]]+.*%ymm' "$y")
y_vmul=$(cnt 'vmulps[[:space:]]+.*%ymm' "$y")
echo "exp ymm AVX2: vcvtps2dq.ymm=$y_ymm (>=1)  vpaddd.ymm=$y_vpaddd (>=1)  vpslld.ymm=$y_vpslld (>=1)  vmulps.ymm=$y_vmul (>=4)"
[ "$y_ymm" -ge 1 ]    || { echo "FAIL: AVX2 exp range-reduction not widened to ymm"; rc=1; }
[ "$y_vpaddd" -ge 1 ] || { echo "FAIL: AVX2 exp 2^n exponent build (vpaddd) not on ymm"; rc=1; }
[ "$y_vpslld" -ge 1 ] || { echo "FAIL: AVX2 exp 2^n exponent build (vpslld) not on ymm"; rc=1; }
[ "$y_vmul" -ge 4 ]   || { echo "FAIL: AVX2 exp polynomial not on ymm (vmulps.ymm<4)"; rc=1; }

# sigmoid + tanh also widen to ymm on AVX2
compile ksig.pp -O4 -OoAPPROXTRANS -OoVECT256 -Cfavx2
[ "$(cnt 'vpaddd[[:space:]]+.*%ymm' "$tmp/ksig.s")" -ge 1 ] || { echo "FAIL: AVX2 sigmoid expf not widened to ymm"; rc=1; }
compile ktanh.pp -O4 -OoAPPROXTRANS -OoVECT256 -Cfavx2
[ "$(cnt 'vpaddd[[:space:]]+.*%ymm' "$tmp/ktanh.s")" -ge 1 ] || { echo "FAIL: AVX2 tanh expf not widened to ymm"; rc=1; }
echo "sig/tanh ymm AVX2: vpaddd.ymm>=1 (expf widened)"

# AVX-only fputype: transcendental must STAY 128-bit (no ymm exponent build) even
# with -OoVECT256, because vpaddd/vpslld ymm need AVX2 -- but an ordinary float
# add loop still widens to ymm, proving VECT256 is otherwise active.
cat > "$tmp/kmix.pp" <<'EOF'
program kmix;
{$mode objfpc}{$H+}
type TS = array of single;
procedure act(a,b: TS); var i: longint; begin for i:=0 to high(a) do a[i]:=exp(b[i]); end;
procedure add(a,b,c: TS); var i: longint; begin for i:=0 to high(a) do a[i]:=b[i]+c[i]; end;
var a,b,c: TS;
begin SetLength(a,64); SetLength(b,64); SetLength(c,64); act(a,b); add(a,b,c); Writeln(a[0]:0:3); end.
EOF
compile kmix.pp -O4 -OoAPPROXTRANS -OoVECT256 -Cfavx
km="$tmp/kmix.s"
km_transc_ymm=$(cnt 'vpaddd[[:space:]]+.*%ymm' "$km")
km_ymm=$(cnt '%ymm' "$km")
echo "exp ymm AVX1: transc.vpaddd.ymm=$km_transc_ymm (must be 0)  any.ymm=$km_ymm (>=1, float loop still widened)"
[ "$km_transc_ymm" -eq 0 ] || { echo "FAIL: transc widened to ymm on an AVX-only (no AVX2) fputype"; rc=1; }
[ "$km_ymm" -ge 1 ]        || { echo "FAIL: -OoVECT256 produced no ymm at all on AVX fputype"; rc=1; }
[ "$(cnt 'cvtps2dq' "$km")" -ge 1 ] || { echo "FAIL: AVX1 transc lost its 128-bit expf"; rc=1; }

[ "$rc" -eq 0 ] && echo "PASS: -OoAPPROXTRANS lowers exp/sigmoid/tanh single loops to an inline packed expf only when enabled, widens to 256-bit ymm on an AVX2 fputype under -OoVECT256, and declines indirect/double shapes"
exit "$rc"
