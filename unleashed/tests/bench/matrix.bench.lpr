{ matrix.bench — dense double matrix multiply, repeated.

  A pf-bench benchmark (see deflate.bench for the convention). Workload:
  C = A×B for fixed deterministic 320×320 double matrices, REPS times; the
  checksum folds the rounded entries of C with FNV-1a (identical every rep,
  so PF_BENCH_SCALE only changes the repeat count). The naive triple loop is
  the canonical target for loop interchange / tiling / vectorization /
  unroll-and-jam.

  Sized so one run is ~0.2–2 s at -O2, scale 1. }
program matrix_bench;

{$mode objfpc}{$H+}

uses
  SysUtils;

const
  N = 320;
  BASE_REPS = 24;

type
  TMatrix = array of Double;  { row-major N×N }

function BuildMatrix(ASeed: LongWord): TMatrix;
var
  i: Integer;
  seed: LongWord;
begin
  SetLength(Result, N * N);
  seed := ASeed;
  for i := 0 to N * N - 1 do
  begin
    seed := seed * 1103515245 + 12345;
    Result[i] := ((seed shr 8) and $FFFF) / 65536.0 - 0.5;
  end;
end;

procedure MatMul(const A, B: TMatrix; var C: TMatrix);
var
  i, j, k: Integer;
  s: Double;
begin
  for i := 0 to N - 1 do
    for j := 0 to N - 1 do
    begin
      s := 0.0;
      for k := 0 to N - 1 do
        s := s + A[i * N + k] * B[k * N + j];
      C[i * N + j] := s;
    end;
end;

function Scale: Integer;
var
  s: string;
  v: Integer;
begin
  s := GetEnvironmentVariable('PF_BENCH_SCALE');
  if (s = '') or (not TryStrToInt(s, v)) or (v < 1) then
    v := 1;
  Result := v;
end;

var
  A, B, C: TMatrix;
  i, r, reps: Integer;
  h, e: QWord;
begin
  A := BuildMatrix($1234567);
  B := BuildMatrix($89ABCDE);
  SetLength(C, N * N);
  reps := BASE_REPS div Scale;
  if reps < 1 then reps := 1;
  for r := 1 to reps do
    MatMul(A, B, C);
  h := QWord($CBF29CE484222325);
  for i := 0 to N * N - 1 do
  begin
    e := QWord(Int64(Round(C[i] * 4096)));
    h := (h xor e) * QWord($100000001B3);
  end;
  Writeln(Format('matrix n=%d fnv=%.16x', [N, h]));
end.
