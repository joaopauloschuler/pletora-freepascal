{ gather.bench — an indexed (non-unit-stride) single-precision sum reduction
  over an out-of-cache array, in the shape the fork's -OoGATHER pass targets:

      for i := 0 to n-1 do
        s := s + a[idx[i]];

  The element of a[] is read through a computed int32 index, so a plain vmovups
  cannot widen the load; -OoGATHER lowers it to the AVX2 vgatherdps gather
  (VF=4 xmm, VF=8 ymm under -OoVECT256), while without the switch the loop
  stays scalar (one vaddss per element).  The index array is a pseudo-random
  permutation-ish fill across the whole 16 MiB array, so nearly every gather
  lane is a cache miss — the memory-bound worst case where an AVX2 gather is
  NOT guaranteed to beat scalar loads (it issues the same cache-line fetches);
  the bench reports whichever way it goes.

  a[] holds small integer values (0..3) and n*3 < 2^24, so every partial sum is
  an exactly-representable integer in single and the reduction is independent
  of summation order: the checksum is identical with and without the switch and
  an A/B checksum gate passes.  Arrays and counters are locals of the kernel
  function (the pass requires simple non-aliased dynamic-array bases and a
  plain, non-address-taken counter).

  A/B usage (same compiler, switch off vs on):
    pf-bench ab --compiler-a <ppcx64> --compiler-b <ppcx64> \
      --flags=-O4 --flags-a=-OoNOGATHER --flags-b=-OoGATHER \
      --filter gather

  Workload: a fixed N-element gather-sum run REPS times; the checksum folds the
  per-rep sums so PF_BENCH_SCALE only changes the repeat count. }
program gather_bench;

{$mode objfpc}{$H+}
{$Q-}{$R-}

uses
  SysUtils;

const
  BASE_REPS = 60;
  N = 4*1024*1024;     { 4M singles = 16 MiB a[] + 16 MiB idx[], well past L2 }

type
  TSA = array of single;
  TIA = array of longint;

{ the indexed-gather sum reduction, isolated in its own function with VALUE
  array parameters and a plain local accumulator: the recognizer requires
  simple non-aliased (non-address-taken) array bases and accumulator, so the
  SetLength/@-taking staging must stay OUTSIDE this function }
function gsum(a: TSA; idx: TIA; n: longint): single;
var
  i: longint;
  s: single;
begin
  s := 0;
  for i := 0 to n-1 do
    s := s + a[idx[i]];
  gsum := s;
end;

function kernel(reps: longint): cardinal;
var
  a: TSA;
  idx: TIA;
  i, r: longint;
  s: single;
  rng: longword;
  acc, bits: cardinal;
begin
  SetLength(a, N);
  SetLength(idx, N);
  { small exact-in-single integer values: every partial sum stays below 2^24,
    so the packed partial-sum reorder cannot round and the result is exact }
  for i := 0 to N-1 do
    a[i] := single((i*3+1) and 3);
  { pseudo-random indices across the whole array (out-of-cache gather),
    including duplicates and both boundaries }
  rng := 2166136261;
  for i := 0 to N-1 do
    begin
      rng := rng xor (rng shl 13); rng := rng xor (rng shr 17); rng := rng xor (rng shl 5);
      idx[i] := longint(rng mod longword(N));
    end;

  acc := $811C9DC5;
  for r := 0 to reps-1 do
    begin
      s := gsum(a, idx, N);
      { fold the per-rep sum into the checksum, and perturb one index so the
        whole reduction cannot be hoisted out of r (the perturbed slot is put
        back to a valid in-range index) }
      bits := PCardinal(@s)^;
      acc := (acc xor bits) * 16777619;
      idx[r mod N] := (idx[r mod N] + 1) mod N;
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
  Writeln(Format('gather n=%d reps=%d crc=%.8x', [N, reps, crc]));
end.
