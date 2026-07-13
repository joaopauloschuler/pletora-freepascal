#!/usr/bin/env bash
# Micro-benchmark for -OoDEVIRT: a hot loop making many small virtual calls on a
# provable (locally constructed, never rebound) receiver. Times the same program
# built without and with the switch and prints a rough speedup. Bounded well
# under the experiment budget: ulimit + timeout on the binaries.
#
# Usage: unleashed/tests/devirt_bench.sh [path-to-ppcx64]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/bench.pp" <<'EOF'
program bench;
{$mode objfpc}{$H+}
type
  TStep = class
    function Delta(x: longint): longint; virtual;
  end;
  TInc = class(TStep)
    function Delta(x: longint): longint; override;
  end;
function TStep.Delta(x: longint): longint; begin Result:=x; end;
function TInc.Delta(x: longint): longint; begin Result:=x+1; end;

{ the receiver must be a LOCAL variable for the intra-procedural provenance
  analysis to prove it monomorphic }
function run: int64;
var
  s: TStep;
  i, j: longint;
  acc: int64;
begin
  s := TInc.Create;                 { provable receiver: never rebound }
  acc := 0;
  for j := 1 to 2000 do
    for i := 1 to 1000000 do
      acc := acc + s.Delta(i);      { hot virtual call -> devirtualized }
  s.Free;
  Result := acc;
end;

begin
  Writeln(run);
end.
EOF

build_and_time() {
  local tag="$1"; shift
  "$CC" -Fu"$RTL" -O3 "$@" "$tmp/bench.pp" -o"$tmp/bench_$tag" >/dev/null 2>&1
  local start end
  start=$(date +%s.%N)
  ( ulimit -v 3000000; timeout 120 "$tmp/bench_$tag" >/dev/null )
  end=$(date +%s.%N)
  awk -v s="$start" -v e="$end" 'BEGIN{printf "%.3f", e-s}'
}

t_off=$(build_and_time off)
t_on=$(build_and_time on -OoDEVIRT)

echo "no  -OoDEVIRT : ${t_off}s"
echo "with -OoDEVIRT: ${t_on}s"
awk -v o="$t_off" -v n="$t_on" 'BEGIN{ if (n>0) printf "speedup       : %.2fx\n", o/n }'
