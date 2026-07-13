program fieldbase_tile_runtime;
{$mode objfpc}{$H+}{$Q-}{$R-}
{ Bit-exact runtime fixture for loop tiling's object-field array-base recognition
  (Self.FData-style bases).  MatMul below is a perfect three-deep matmul-shaped
  reduction nest  C[i*N+j] := C[i*N+j] + A[i*K+k]*B[k*N+j]  over dynamic-array
  FIELDS of a class -- the exact TNNetVolume.FData shape the fork previously
  refused to tile because the base was not a plain local/param.  -OoLOOPTILE (an
  -O4 default) cache-blocks it into 64x64 tiles with the point loops reordered
  i/k/j.  The printed checksum MUST be identical whether tiling fired (-O4) or not
  (-O-): the write index i*N+j is injective over the (i,j) rectangle, so each cell
  is summed independently in unchanged k order, bit-exact; the integer element
  type makes it exact under any visit order without fast-math. }

type
  TMat = class
    FA, FB, FC : array of int64;
    rows, cols, inner : longint;
    procedure Init;
    procedure MatMul;   { FC[i*cols+j] := FC[..] + FA[i*inner+k]*FB[k*cols+j] }
  end;

procedure TMat.Init;
var i : longint;
begin
  SetLength(FA, rows*inner); SetLength(FB, inner*cols); SetLength(FC, rows*cols);
  for i := 0 to rows*inner-1 do FA[i] := (i mod 7) - 3;
  for i := 0 to inner*cols-1 do FB[i] := (i mod 5) - 2;
  for i := 0 to rows*cols-1 do FC[i] := 0;
end;

procedure TMat.MatMul;
var i, j, k : longint;
begin
  for i := 0 to rows-1 do
    for j := 0 to cols-1 do
      for k := 0 to inner-1 do
        FC[i*cols+j] := FC[i*cols+j] + FA[i*inner+k]*FB[k*cols+j];
end;

var
  v : TMat;
  i : longint;
  acc : int64;
begin
  v := TMat.Create;
  v.rows := 70; v.cols := 66; v.inner := 74;
  v.Init;
  v.MatMul;
  acc := 0;
  for i := 0 to v.rows*v.cols-1 do
    acc := acc + v.FC[i]*(i+1);
  Writeln('checksum=', acc);
end.
