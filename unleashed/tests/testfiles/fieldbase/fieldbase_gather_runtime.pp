program fieldbase_gather_runtime;
{$mode objfpc}{$H+}{$Q-}{$R-}
{ Bit-exact runtime fixture for the AVX2 gather vectorizer's object-field
  array-base recognition (Self.FData-style bases).  GSum below is an indexed
  (non-unit-stride) sum reduction  s := s + FData[FIdx[i]]  whose gathered data
  array AND index array are dynamic-array FIELDS of a class -- the TNNetVolume-
  shaped gather the fork previously refused because the bases were not plain
  locals/params.  -OoGATHER (opt-in, AVX2) widens the indexed load with vgatherdps
  and snapshots each field base into a preheader pointer temp under the whole-loop
  gates.  The FData values are exact small integers whose sum stays well below
  2^24, so the reduction is order-independent in single precision: the printed
  checksum MUST be identical whether the gather fired (-O4 -OoGATHER -Cfavx2) or
  not (-O-).  (This file compiles/runs correctly with any flags; without an AVX2
  target the loop simply stays scalar.) }

type
  TVol = class
    FData : array of single;
    FIdx  : array of longint;
    function GSum(n : longint) : single;
  end;

function TVol.GSum(n : longint) : single;
var i : longint; s : single;
begin
  s := 0;
  for i := 0 to n-1 do
    s := s + FData[FIdx[i]];
  GSum := s;
end;

const NIDX = 257;   { deliberately not a multiple of 4/8, to exercise the tail }
var
  v : TVol;
  i : longint;
begin
  v := TVol.Create;
  SetLength(v.FData, 100);
  SetLength(v.FIdx, NIDX);
  for i := 0 to 99 do
    v.FData[i] := (i mod 17);
  for i := 0 to NIDX-1 do
    v.FIdx[i] := (i*13 + 7) mod 100;
  Writeln('checksum=', v.GSum(NIDX):0:1);
end.
