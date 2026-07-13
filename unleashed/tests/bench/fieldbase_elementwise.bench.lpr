{ fieldbase_elementwise.bench — an element-wise product expressed as a CLASS
  METHOD over the object's own dynamic-array FIELDS, the exact TNNetVolume.FData
  shape the fork's element-wise vectorizer previously refused to touch (its
  simple-var rule rejected  Self.FData -style object-field array bases, so no
  loop optimization fired inside real neural-api methods).

  The element-wise vectorizer now accepts an object-field array base by
  pre-hoisting the invariant field load into a preheader snapshot and running
  the existing recognizer against it, so

      procedure TVol.Mul;                   { Self.FA[i] := Self.FB[i] * Self.FC[i] }
      begin for i:=0 to High(FA) do FA[i]:=FB[i]*FC[i]; end;

  now widens to a packed movups/mulps main loop + scalar tail — inside the
  method, over the fields, with no manual staging into locals.

  Subset: distinct destination field, same index for reads and write, so the
  transform is BIT-EXACT and the A/B checksum gate passes.  A/B usage (same fork
  compiler, vectorizer OFF vs ON):

    pf-bench ab --compiler-a <ppcx64> --compiler-b <ppcx64> \
      --flags=-O4 --flags-a=-OoNOVECTORIZE --flags-b=-OoVECTORIZE \
      --filter fieldbase_elementwise

  Workload: a fixed-size vector mapped REPS times through the method; the
  checksum folds the final field so PF_BENCH_SCALE only changes the repeat
  count. }
program fieldbase_elementwise_bench;

{$mode objfpc}{$H+}

uses
  SysUtils;

const
  BASE_REPS = 20000;
  N = 8192;            { singles = 32 KiB, L1/L2 resident; multiple of 4 }

type
  TVol = class
    FA, FB, FC : array of single;
    procedure Init;
    procedure Mul;     { FA[i] := FB[i] * FC[i]  — the field-base element-wise loop }
  end;

procedure TVol.Init;
var i : longint;
begin
  SetLength(FA, N); SetLength(FB, N); SetLength(FC, N);
  for i := 0 to N-1 do
    begin
      FB[i] := -4.0 + 8.0 * i / (N-1);
      FC[i] := 0.25 + 0.5 * ((i mod 5) - 2);
      FA[i] := 0.0;
    end;
end;

procedure TVol.Mul;
var i : longint;
begin
  for i := 0 to High(FA) do
    FA[i] := FB[i] * FC[i];
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
      v.Mul;
      { feed one element back so the whole map cannot be hoisted out of r }
      v.FB[r mod N] := v.FA[r mod N] * 1.0000001;
    end;

  acc := $811C9DC5;
  for i := 0 to N-1 do
    begin
      fv := v.FA[i];
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
  Writeln(Format('fieldbase_elementwise n=%d reps=%d crc=%.8x', [N, reps, crc]));
end.
