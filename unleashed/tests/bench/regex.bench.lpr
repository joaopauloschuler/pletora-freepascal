{ regex.bench — regex-scan a fixed synthetic text repeatedly.

  A pf-bench benchmark (see deflate.bench for the convention). Workload:
  scan a deterministic ~256 KB text with the in-tree regexpr engine
  (TRegExpr) REPS times, counting matches and folding every match position
  and length with FNV-1a. The backtracking matcher is dense branchy integer
  code — exactly the shape that stresses jump threading, case clustering
  and block ordering. The checksum is identical every rep, so
  PF_BENCH_SCALE only changes the repeat count.

  Sized so one run is ~0.2–2 s at -O2, scale 1. }
program regex_bench;

{$mode objfpc}{$H+}

uses
  SysUtils, regexpr;

const
  TEXT_LEN = 256 * 1024;
  BASE_REPS = 20;
  PATTERN = '[a-z]+[0-9]{2,4}(_[a-z0-9]+)*';

function BuildText: string;
const
  Alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789_ ';
var
  i: Integer;
  seed: LongWord;
begin
  SetLength(Result, TEXT_LEN);
  seed := $F00DFACE;
  for i := 1 to TEXT_LEN do
  begin
    seed := seed * 1103515245 + 12345;
    Result[i] := Alphabet[1 + (seed shr 16) mod LongWord(Length(Alphabet))];
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
  Text: string;
  Re: TRegExpr;
  r, reps: Integer;
  Count: Integer;
  h: QWord;
begin
  Text := BuildText;
  reps := BASE_REPS div Scale;
  if reps < 1 then reps := 1;
  Count := 0;
  h := 0;
  Re := TRegExpr.Create(PATTERN);
  try
    for r := 1 to reps do
    begin
      Count := 0;
      h := QWord($CBF29CE484222325);
      if Re.Exec(Text) then
        repeat
          Inc(Count);
          h := (h xor QWord(Re.MatchPos[0])) * QWord($100000001B3);
          h := (h xor QWord(Re.MatchLen[0])) * QWord($100000001B3);
        until not Re.ExecNext;
    end;
  finally
    Re.Free;
  end;
  Writeln(Format('regex matches=%d fnv=%.16x', [Count, h]));
end.
