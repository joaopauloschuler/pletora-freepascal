program fieldbase_runtime;
{$mode objfpc}{$H+}{$Q-}{$R-}
{ Bit-exact runtime fixture for the element-wise vectorizer's object-field
  array-base recognition (Self.FData-style bases, hoisted into a preheader
  snapshot).  Every element-wise / reduction loop below runs over dynamic-array
  fields of a class -- the exact TNNetVolume.FData shape the fork previously
  refused to vectorize.  The printed checksum MUST be identical whether the
  vectorizer fired (-O4 -OoVECTORIZE ...) or not (-O-): the packed body is
  bit-identical to the scalar loop (same per-lane op, same order; the FP
  reduction reorder is licensed only under -OoFASTMATH, which the check passes
  to BOTH builds so the compared runs use the same arithmetic). }

type
  TVol = class
    FA, FB, FC : array of single;
    FD, FE     : array of double;
    procedure AddArr;         { a := b + c            (vok_arr_arr, single)   }
    procedure MulArr;         { a := b * c            (vok_arr_arr, single)   }
    procedure ScaleScalar(k : single);  { a := b * k  (vok_arr_scalar)       }
    procedure CopyArr;        { a := b                (vok_copy)              }
    procedure ScaleDbl(k : double);     { d := d * k  (double, VF=2)         }
    function  Dot : single;   { s := s + b*c          (reduction dot product) }
    function  Sum : double;   { s := s + d            (reduction sum, double) }
  end;

procedure TVol.AddArr;
var i : longint;
begin
  for i := 0 to High(FA) do
    FA[i] := FB[i] + FC[i];
end;

procedure TVol.MulArr;
var i : longint;
begin
  for i := 0 to High(FA) do
    FA[i] := FB[i] * FC[i];
end;

procedure TVol.ScaleScalar(k : single);
var i : longint;
begin
  for i := 0 to High(FA) do
    FA[i] := FB[i] * k;
end;

procedure TVol.CopyArr;
var i : longint;
begin
  for i := 0 to High(FA) do
    FA[i] := FB[i];
end;

procedure TVol.ScaleDbl(k : double);
var i : longint;
begin
  for i := 0 to High(FD) do
    FD[i] := FD[i] * k;
end;

function TVol.Dot : single;
var i : longint; s : single;
begin
  s := 0;
  for i := 0 to High(FB) do
    s := s + FB[i]*FC[i];
  Dot := s;
end;

function TVol.Sum : double;
var i : longint; s : double;
begin
  s := 0;
  for i := 0 to High(FD) do
    s := s + FD[i];
  Sum := s;
end;

const N = 257;   { deliberately not a multiple of 4/8, to exercise the tail }
var
  v : TVol;
  i : longint;
  acc : double;
begin
  v := TVol.Create;
  SetLength(v.FA, N); SetLength(v.FB, N); SetLength(v.FC, N);
  SetLength(v.FD, N); SetLength(v.FE, N);
  for i := 0 to N-1 do
    begin
      v.FB[i] := (i mod 13) * 0.5 - 3.0;
      v.FC[i] := (i mod 7)  * 0.25 + 1.0;
      v.FD[i] := (i mod 11) * 1.5 - 2.0;
    end;

  acc := 0;
  v.AddArr;       for i := 0 to N-1 do acc := acc + v.FA[i];
  v.MulArr;       for i := 0 to N-1 do acc := acc + v.FA[i]*2.0;
  v.ScaleScalar(1.5);
                  for i := 0 to N-1 do acc := acc + v.FA[i];
  v.CopyArr;      for i := 0 to N-1 do acc := acc + v.FA[i];
  v.ScaleDbl(3.0);
                  for i := 0 to N-1 do acc := acc + v.FD[i];
  acc := acc + v.Dot;
  acc := acc + v.Sum;

  Writeln('checksum=', acc:0:6);
end.
