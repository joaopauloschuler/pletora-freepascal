{ deflate.bench — DEFLATE-compress a fixed, semi-compressible buffer repeatedly.

  A pf-bench benchmark: a self-timing-free program that runs a FIXED
  deterministic workload and prints ONE checksum line, so pf-bench can assert
  two compilers produced the same answer before comparing their speed.

  Workload: build a ~128 KB pseudo-random-but-deterministic byte buffer with
  some repetition (so DEFLATE has real work to do), then compress it REPS
  times with the in-tree paszlib (pure Pascal — its match finder and Huffman
  coder are branchy real code the optimizer must not break). The checksum is
  the CRC32 of the compressed output. REPS scales with the env var
  PF_BENCH_SCALE (default 1) so the workload can be shrunk for a fast smoke
  run WITHOUT changing the checksum — the compressed bytes are identical
  every rep, only the repeat count varies.

  Sized so one run is ~0.2–2 s at -O2, scale 1. }
program deflate_bench;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, zstream, paszlib;

const
  BUF_LEN = 128 * 1024;
  BASE_REPS = 60;

function BuildBuffer: TBytes;
var
  i: Integer;
  seed: LongWord;
begin
  SetLength(Result, BUF_LEN);
  seed := $1234567;
  for i := 0 to BUF_LEN - 1 do
  begin
    { A cheap deterministic LCG, folded so runs of similar bytes appear and
      DEFLATE finds matches — otherwise the data is incompressible. }
    seed := seed * 1103515245 + 12345;
    Result[i] := Byte((seed shr 16) and $FF) and Byte(((i shr 5) and 7) + $F8);
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

function CompressOnce(const ABuf: TBytes): TBytes;
var
  Dest: TMemoryStream;
  Z: TCompressionStream;
begin
  Dest := TMemoryStream.Create;
  try
    Z := TCompressionStream.Create(clDefault, Dest);
    try
      Z.WriteBuffer(ABuf[0], Length(ABuf));
    finally
      Z.Free; { flushes }
    end;
    SetLength(Result, Dest.Size);
    Move(Dest.Memory^, Result[0], Dest.Size);
  finally
    Dest.Free;
  end;
end;

var
  Buf, Comp: TBytes;
  i, reps: Integer;
  c: Cardinal;
begin
  Buf := BuildBuffer;
  reps := BASE_REPS div Scale;
  if reps < 1 then reps := 1;
  Comp := nil;
  for i := 1 to reps do
    Comp := CompressOnce(Buf);
  c := crc32(0, nil, 0);
  c := crc32(c, PAnsiChar(@Comp[0]), Length(Comp));
  Writeln(Format('deflate len=%d crc=%.8x', [Length(Comp), c]));
end.
