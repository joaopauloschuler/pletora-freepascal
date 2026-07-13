program fieldbase_interchange_runtime;
{$mode objfpc}{$H+}{$Q-}{$R-}
{ Bit-exact runtime fixture for loop interchange's object-field array-base
  recognition (Self.FData-style bases).  Each method below is a perfect two-deep
  COLUMN-MAJOR counted nest over dynamic-array FIELDS of a class -- the exact
  TNNetVolume.FData shape the fork previously refused to reorder because the base
  was not a plain local/param.  With the inner counter striding the non-contiguous
  dimension, -OoLOOPINTERCHANGE (an -O4 default) swaps the loops so the inner loop
  strides the contiguous dimension.  The printed checksum MUST be identical whether
  interchange fired (-O4) or not (-O-): the write index i*cols+j is injective over
  the (i,j) rectangle here, so reordering the visit order is bit-exact, and the
  integer accumulator makes the reduction reorder exact without fast-math. }

type
  TMat = class
    FA, FB, FC : array of longint;
    rows, cols : longint;
    procedure Init;
    procedure MapColMajor;           { FA[i*cols+j] := FB*3 + FC   (subset R)  }
    function  ReduceColMajor : int64; { s := s + FB[i*cols+j]      (subset S)  }
  end;

procedure TMat.Init;
var i : longint;
begin
  SetLength(FA, rows*cols); SetLength(FB, rows*cols); SetLength(FC, rows*cols);
  for i := 0 to rows*cols-1 do
    begin
      FB[i] := (i mod 13) - 6;
      FC[i] := (i mod 7) + 1;
      FA[i] := 0;
    end;
end;

procedure TMat.MapColMajor;
var i, j : longint;
begin
  for j := 0 to cols-1 do
    for i := 0 to rows-1 do
      FA[i*cols+j] := FB[i*cols+j]*3 + FC[i*cols+j];
end;

function TMat.ReduceColMajor : int64;
var i, j : longint; s : int64;
begin
  s := 0;
  for j := 0 to cols-1 do
    for i := 0 to rows-1 do
      s := s + FB[i*cols+j]*7;
  ReduceColMajor := s;
end;

var
  v : TMat;
  i : longint;
  acc : int64;
begin
  v := TMat.Create;
  v.rows := 77; v.cols := 91;
  v.Init;
  v.MapColMajor;
  acc := 0;
  for i := 0 to v.rows*v.cols-1 do
    acc := acc + v.FA[i]*(i+1);
  acc := acc + v.ReduceColMajor;
  Writeln('checksum=', acc);
end.
