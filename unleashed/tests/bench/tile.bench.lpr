{ tile.bench — a dense single-precision matmul  C := A*B  in the classic
  matmul-shaped reduction nest the fork's -OoLOOPTILE pass targets:

      for i := 0 to N-1 do
        for j := 0 to N-1 do
          for k := 0 to N-1 do
            c[i*N+j] := c[i*N+j] + a[i*N+k]*b[k*N+j];

  The write c[i*N+j] accumulates a full k-reduction, a[i*N+k] is reused across j,
  and b[k*N+j] is reused across i -- but in the naive i/j/k order the inner k loop
  strides b by N (a cache line skipped per step) and, on a matrix larger than L2,
  the whole of b is re-streamed from memory for every output row.

  -OoLOOPTILE blocks the i and j loops into NxN cache-sized tiles and reorders the
  point loops to i/k/j (interchanging j and k) so the inner loop strides the
  contiguous dimension and a K*tile panel of b stays cache-resident across the
  tile's rows.  The transform is BIT-EXACT for this shape (the write index i*N+j is
  injective, so no output cell's k-reduction is ever reordered), so the checksum is
  identical with and without the switch and an A/B checksum gate passes.  The
  arrays and counters are locals of the kernel procedure (the pass requires simple
  non-aliased dynamic-array bases and plain, non-address-taken counters), matching
  how a neural-api dense/conv kernel would stage a TNNetVolume slice into locals.

  Workload: a fixed NxN*NxN matmul repeated REPS times; the checksum folds the
  final output so PF_BENCH_SCALE only changes the repeat count. }
program tile_bench;

{$mode objfpc}{$H+}

uses
  SysUtils;

const
  BASE_REPS = 4;
  N = 768;             { 3 * 768^2 singles = 6.75 MiB of matrices, well past L2 }

type
  TSA = array of single;

{ dense matmul over local dynamic arrays -- the tileable nest.  Returns an FNV
  fold of the final output so the repeat count does not change the checksum. }
function kernel(reps: longint): cardinal;
var
  a, b, c: TSA;
  i, j, k, r: longint;
  acc, bits: cardinal;
  fv: single;
begin
  SetLength(a, N*N);
  SetLength(b, N*N);
  SetLength(c, N*N);
  for i := 0 to N*N-1 do
    begin
      a[i] := -0.6 + ((i*7) mod 13) * 0.1;
      b[i] := -0.5 + ((i*3) mod 11) * 0.1;
    end;

  for r := 0 to reps-1 do
    begin
      for i := 0 to N*N-1 do
        c[i] := 0.0;
      { the matmul-shaped reduction nest the pass tiles }
      for i := 0 to N-1 do
        for j := 0 to N-1 do
          for k := 0 to N-1 do
            c[i*N+j] := c[i*N+j] + a[i*N+k]*b[k*N+j];
      { feed one element back so the whole matmul cannot be hoisted out of r }
      b[r mod (N*N)] := b[r mod (N*N)] + c[0] * 1.0000001e-9;
    end;

  acc := $811C9DC5;
  for i := 0 to N*N-1 do
    begin
      fv := c[i];
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
  Writeln(Format('tile n=%d reps=%d crc=%.8x', [N, reps, crc]));
end.
