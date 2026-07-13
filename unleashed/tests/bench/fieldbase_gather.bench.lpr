{ fieldbase_gather.bench — an indexed (non-unit-stride) sum reduction expressed
  as a CLASS METHOD over the object's own dynamic-array FIELDS, the exact
  TNNetVolume.FData shape the fork's -OoGATHER pass previously refused to touch
  (its simple-var rule rejected  Self.FData -style object-field array bases for
  BOTH the gathered data array and the index array, so the AVX2 gather never
  fired inside real neural-api methods).

  -OoGATHER (opt-in, needs -Cfavx2) now accepts object-field bases for both
  arrays, snapshotting each into a preheader pointer temp under the whole-loop
  soundness gates, so

      function TVol.GSum(n): single;        { s := s + FData[FIdx[i]] }

  widens the indexed load to vgatherdps (xmm VF=4; ymm VF=8 under -OoVECT256)
  — inside the method, over the fields, with no manual staging into locals.

  BIT-EXACT by construction: FData holds exact small integers and each call's
  sum stays far below 2^24, so the single-precision reduction is
  order-independent and the A/B checksum gate passes despite the gather's
  reassociation.  A/B usage (same fork compiler, gather OFF vs ON; gather is
  opt-in so only side B enables it):

    pf-bench ab --compiler-a <ppcx64> --compiler-b <ppcx64> \
      --flags="-O4 -Cfavx2 -OoVECT256" --flags-b=-OoGATHER \
      --filter fieldbase_gather

  Workload: NIDX indexed loads per call, repeated REPS times; one index is
  permuted between calls (exact integers) so the reduction cannot be hoisted
  out of the rep loop; the checksum folds every per-call sum. }
program fieldbase_gather_bench;

{$mode objfpc}{$H+}

uses
  SysUtils;

const
  BASE_REPS = 4000;
  NDATA = 16384;       { 64 KiB of singles, L2 resident — gather is latency-bound }
  NIDX  = 65537;       { deliberately not a multiple of 4/8, to exercise the tail }

type
  TVol = class
    FData : array of single;
    FIdx  : array of longint;
    procedure Init;
    function GSum(n : longint) : single;   { the field-base indexed reduction }
  end;

procedure TVol.Init;
var i : longint;
begin
  SetLength(FData, NDATA); SetLength(FIdx, NIDX);
  for i := 0 to NDATA-1 do
    FData[i] := (i mod 17);          { exact small integers: 0..16 }
  for i := 0 to NIDX-1 do
    FIdx[i] := (i*13 + 7) mod NDATA; { in-range, non-unit-stride }
end;

function TVol.GSum(n : longint) : single;
var i : longint; s : single;
begin
  s := 0;
  for i := 0 to n-1 do
    s := s + FData[FIdx[i]];
  GSum := s;
end;

function run(reps: longint): cardinal;
var
  v : TVol;
  r : longint;
  acc, bits : cardinal;
  fv : single;
begin
  v := TVol.Create;
  v.Init;

  acc := $811C9DC5;
  for r := 0 to reps-1 do
    begin
      fv := v.GSum(NIDX);            { <= 16*65537 = 1_048_592 < 2^24: exact }
      bits := PCardinal(@fv)^;
      acc := (acc xor bits) * 16777619;
      { permute one index between calls (exact ints) so the reduction cannot
        be hoisted out of the rep loop }
      v.FIdx[r mod NIDX] := (v.FIdx[r mod NIDX] + 7919) mod NDATA;
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
  Writeln(Format('fieldbase_gather n=%d reps=%d crc=%.8x', [NIDX, reps, crc]));
end.
