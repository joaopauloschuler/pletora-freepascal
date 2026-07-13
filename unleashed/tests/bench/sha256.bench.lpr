{ sha256.bench — SHA-256 a fixed 1 MiB buffer repeatedly.

  A pf-bench benchmark (see deflate.bench for the convention). Workload: hash
  a deterministic 1 MiB buffer REPS times with the in-tree fcl-hash SHA-256 —
  a rotate/xor/add integer hot loop, the classic hash-kernel optimizer
  workload. The checksum line is the hex digest itself (identical every rep,
  so PF_BENCH_SCALE only changes the repeat count).

  Sized so one run is ~0.2–2 s at -O2, scale 1. }
program sha256_bench;

{$mode objfpc}{$H+}

uses
  SysUtils, fpsha256;

const
  BUF_LEN = 1024 * 1024;
  BASE_REPS = 100;

function BuildBuffer: TBytes;
var
  i: Integer;
  seed: LongWord;
begin
  SetLength(Result, BUF_LEN);
  seed := $CAFEBABE;
  for i := 0 to BUF_LEN - 1 do
  begin
    seed := seed * 1664525 + 1013904223;
    Result[i] := Byte(seed shr 24);
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
  Buf: TBytes;
  i, reps: Integer;
  Hex: AnsiString;
begin
  Buf := BuildBuffer;
  reps := BASE_REPS div Scale;
  if reps < 1 then reps := 1;
  Hex := '';
  for i := 1 to reps do
    TSHA256.DigestHexa(Buf, Hex);
  Writeln(Format('sha256 len=%d digest=%s', [BUF_LEN, LowerCase(Hex)]));
end.
