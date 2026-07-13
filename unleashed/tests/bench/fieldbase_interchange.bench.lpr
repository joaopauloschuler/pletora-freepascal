{ fieldbase_interchange.bench — a column-major element-wise map expressed as a
  CLASS METHOD over the object's own dynamic-array FIELDS, the exact
  TNNetVolume.FData shape the fork's -OoLOOPINTERCHANGE pass previously refused to
  touch (its simple-var rule rejected  Self.FData -style object-field array bases,
  so no interchange fired inside real neural-api methods).

  Loop interchange now accepts an object-field array base directly (the reorder
  copies the body verbatim, so no hoisting is needed) under a whole-nest soundness
  gate.  The column-major nest

      procedure TVol.MapColMajor;              { FB[i*W+j] := FA[i*W+j]*1.5+0.25 }
      begin for j:=0 to W-1 do for i:=0 to H-1 do FB[i*W+j]:=FA[i*W+j]*1.5+0.25; end;

  strides the non-contiguous dimension in its inner loop (a cache line skipped per
  step), so on a matrix past L2 nearly every access is a cache miss; interchange
  swaps the loops so the inner loop walks the contiguous dimension.

  Subset R: distinct destination field, same index for read and write, so the
  transform is BIT-EXACT and the A/B checksum gate passes.  A/B (same fork
  compiler, interchange OFF vs ON):

    pf-bench ab --compiler-a <ppcx64> --compiler-b <ppcx64> \
      --flags=-O4 --flags-a=-OoNOLOOPINTERCHANGE --flags-b=-OoLOOPINTERCHANGE \
      --filter fieldbase_interchange }
program fieldbase_interchange_bench;

{$mode objfpc}{$H+}

uses
  SysUtils;

const
  BASE_REPS = 12;
  H = 2048;
  W = 2048;            { H*W = 4,194,304 singles = 16 MiB, well past L2 }

type
  TVol = class
    FA, FB : array of single;
    procedure Init;
    procedure MapColMajor;   { the field-base column-major interchangeable nest }
  end;

procedure TVol.Init;
var i : longint;
begin
  SetLength(FA, H*W); SetLength(FB, H*W);
  for i := 0 to H*W-1 do
    begin
      FA[i] := -4.0 + 8.0 * i / (H*W-1);
      FB[i] := 0.0;
    end;
end;

procedure TVol.MapColMajor;
var i, j : longint;
begin
  for j := 0 to W-1 do
    for i := 0 to H-1 do
      FB[i*W+j] := FA[i*W+j]*1.5 + 0.25;
end;

function run(reps: longint): cardinal;
var
  v : TVol;
  i, r : longint;
  acc, bits : cardinal;
  fv : single;
begin
  v := TVol.Create;
  v.Init;

  for r := 0 to reps-1 do
    begin
      v.MapColMajor;
      { feed one element back so the whole map cannot be hoisted out of r }
      v.FA[r mod (H*W)] := v.FB[r mod (H*W)] * 1.0000001;
    end;

  acc := $811C9DC5;
  for i := 0 to H*W-1 do
    begin
      fv := v.FB[i];
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
  Writeln(Format('fieldbase_interchange h=%d w=%d reps=%d crc=%.8x', [H, W, reps, crc]));
end.
