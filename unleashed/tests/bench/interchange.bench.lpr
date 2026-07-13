{ interchange.bench — a column-major traversal of a large flat 2D Single array,
  in the shape the fork's -OoLOOPINTERCHANGE pass targets:

      for j := 0 to W-1 do
        for i := 0 to H-1 do
          b[i*W+j] := a[i*W+j]*c + d;

  The inner loop strides the NON-contiguous dimension (stride W elements = one
  cache line skipped per step), so on a matrix larger than L2 nearly every
  access is a cache miss.  -OoLOOPINTERCHANGE reorders the nest so the inner loop
  strides the contiguous dimension (stride 1), turning the stream into unit-step
  cache-line-friendly accesses.

  This is the element-wise "map" subset (subset R: write array b distinct from
  read array a, same index for read and write), so the interchange is BIT-EXACT
  -- the checksum is identical with and without the switch, and an A/B checksum
  gate passes.  The arrays and counters are locals of the kernel procedure (the
  pass requires simple non-aliased dynamic-array bases and plain, non-address-
  taken counters), matching how a neural-api kernel would stage a TNNetVolume
  slice into locals.

  Workload: a fixed HxW matrix mapped REPS times; the checksum folds the final
  output so PF_BENCH_SCALE only changes the repeat count. }
program interchange_bench;

{$mode objfpc}{$H+}

uses
  SysUtils;

const
  BASE_REPS = 12;
  H = 2048;
  W = 2048;            { H*W = 4,194,304 singles = 16 MiB, well past L2 }

type
  TSA = array of single;

{ column-major element-wise map over local dynamic arrays -- the interchangeable
  nest.  Returns a fold of the final output so the repeat count does not change
  the checksum. }
function kernel(reps: longint): cardinal;
var
  a, b: TSA;
  i, j, r: longint;
  acc, bits: cardinal;
  fv: single;
begin
  SetLength(a, H*W);
  SetLength(b, H*W);
  for i := 0 to H*W-1 do
    a[i] := -4.0 + 8.0 * i / (H*W-1);
  for i := 0 to H*W-1 do
    b[i] := 0.0;

  for r := 0 to reps-1 do
    begin
      { the non-contiguous column-major nest the pass interchanges }
      for j := 0 to W-1 do
        for i := 0 to H-1 do
          b[i*W+j] := a[i*W+j]*1.5 + 0.25;
      { feed one element back so the whole map cannot be hoisted out of r }
      a[r mod (H*W)] := b[r mod (H*W)] * 1.0000001;
    end;

  acc := $811C9DC5;
  for i := 0 to H*W-1 do
    begin
      fv := b[i];
      bits := PCardinal(@fv)^;
      acc := (acc xor bits) * 16777619;
    end;
  kernel := acc;
end;

var
  reps, scale: longint;
  s: string;
  crc: cardinal;
begin
  scale := 1;
  s := GetEnvironmentVariable('PF_BENCH_SCALE');
  if s <> '' then
    if not TryStrToInt(s, scale) then scale := 1;
  if scale < 1 then scale := 1;
  reps := BASE_REPS div scale;
  if reps < 1 then reps := 1;

  crc := kernel(reps);
  Writeln(Format('interchange h=%d w=%d reps=%d crc=%.8x', [H, W, reps, crc]));
end.
