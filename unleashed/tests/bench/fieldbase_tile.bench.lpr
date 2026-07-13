{ fieldbase_tile.bench — a matmul-shaped reduction expressed as a CLASS METHOD
  over the object's own dynamic-array FIELDS, the exact TNNetVolume.FData shape
  the fork's -OoLOOPTILE pass previously refused to touch (its simple-var rule
  rejected  Self.FData -style object-field array bases, so no tiling fired inside
  real neural-api methods).

  Loop tiling now accepts an object-field accumulator array AND field read operands
  directly (the reorder copies the body verbatim, no hoisting) under a whole-nest
  soundness gate.  The matmul reduction

      procedure TMat.MatMul;             { FC[i*N+j] += FA[i*N+k]*FB[k*N+j] }

  strides FB by N in its inner loop (a cache line skipped per step); on a matrix
  past L2 the reused FB panel is re-streamed every pass.  -OoLOOPTILE blocks the i
  and j loops into cache-sized tiles and reorders the point loops i/k/j so the
  inner loop walks the contiguous dimension and a K*tile panel of FB stays cache-
  resident across a tile.

  Injective write index over the (i,j) rectangle => the per-cell reduction order is
  unchanged, so the transform is BIT-EXACT and the A/B checksum gate passes.  A/B
  (same fork compiler, tiling OFF vs ON; -O4 supplies the fast-math the float
  reduction needs on both sides):

    pf-bench ab --compiler-a <ppcx64> --compiler-b <ppcx64> \
      --flags=-O4 --flags-a=-OoNOLOOPTILE --flags-b=-OoLOOPTILE \
      --filter fieldbase_tile }
program fieldbase_tile_bench;

{$mode objfpc}{$H+}

uses
  SysUtils;

const
  BASE_REPS = 4;
  N = 768;             { 3 * 768^2 singles = 6.75 MiB of matrices, well past L2 }

type
  TMat = class
    FA, FB, FC : array of single;
    procedure Init;
    procedure ZeroC;
    procedure MatMul;    { FC[i*N+j] := FC[i*N+j] + FA[i*N+k]*FB[k*N+j] }
  end;

procedure TMat.Init;
var i : longint;
begin
  SetLength(FA, N*N); SetLength(FB, N*N); SetLength(FC, N*N);
  for i := 0 to N*N-1 do
    begin
      FA[i] := -0.6 + ((i*7) mod 13) * 0.1;
      FB[i] := -0.5 + ((i*3) mod 11) * 0.1;
    end;
end;

procedure TMat.ZeroC;
var i : longint;
begin
  for i := 0 to N*N-1 do
    FC[i] := 0.0;
end;

procedure TMat.MatMul;
var i, j, k : longint;
begin
  for i := 0 to N-1 do
    for j := 0 to N-1 do
      for k := 0 to N-1 do
        FC[i*N+j] := FC[i*N+j] + FA[i*N+k]*FB[k*N+j];
end;

function run(reps: longint): cardinal;
var
  v : TMat;
  i, r : longint;
  acc, bits : cardinal;
  fv : single;
begin
  v := TMat.Create;
  v.Init;

  for r := 0 to reps-1 do
    begin
      v.ZeroC;
      v.MatMul;
      { feed one element back so the whole matmul cannot be hoisted out of r }
      v.FB[r mod (N*N)] := v.FB[r mod (N*N)] + v.FC[0] * 1.0000001e-9;
    end;

  acc := $811C9DC5;
  for i := 0 to N*N-1 do
    begin
      fv := v.FC[i];
      bits := PCardinal(@fv)^;
      acc := (acc xor bits) * 16777619;
    end;
  v.Free;
  run := acc;
end;

var
  reps, scale : longint;
  s : string;
  crc : cardinal;
begin
  scale := 1;
  s := GetEnvironmentVariable('PF_BENCH_SCALE');
  if s <> '' then
    if not TryStrToInt(s, scale) then scale := 1;
  if scale < 1 then scale := 1;
  reps := BASE_REPS div scale;
  if reps < 1 then reps := 1;

  crc := run(reps);
  Writeln(Format('fieldbase_tile n=%d reps=%d crc=%.8x', [N, reps, crc]));
end.
