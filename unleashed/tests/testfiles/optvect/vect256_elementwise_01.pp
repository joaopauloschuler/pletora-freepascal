{ %OPT="-O4 -OoVECTORIZE -OoVECT256 -Cfavx2" }
{ AVX-256 (ymm) element-wise vectorization, -OoVECT256 on an AVX2 fputype.
  Each packed lane applies the identical scalar op in the identical order, so
  the 256-bit (8-single / 4-double lanes-per-iteration) result must be
  BIT-EXACT against a scalar recompute for every tail residue -- trip counts
  0..17 exercise every remainder 0..7 (single) / 0..3 (double), plus 100 and
  1000 for the steady state. Covers arr_arr (+,-,*), arr_scalar (b*s, s-b),
  a constant literal operand, plain copy, and the double-precision windows.
  Requires an AVX2 host (the suite machine has avx2+fma per /proc/cpuinfo). }
program vect256_elementwise_01;
{$mode objfpc}{$H+}
procedure works(n: longint; s: single);
var a,b,r: array of single; i: longint; d: single;
begin
  SetLength(a,n); SetLength(b,n); SetLength(r,n);
  for i:=0 to n-1 do begin a[i]:=i*1.5-3.25; b[i]:=i*0.5+1.0; end;

  for i:=0 to n-1 do r[i]:=a[i]+b[i];            { arr_arr + }
  for i:=0 to n-1 do begin d:=a[i]+b[i]; if r[i]<>d then Halt(1); end;

  for i:=0 to n-1 do r[i]:=a[i]-b[i];            { arr_arr - (non-commutative) }
  for i:=0 to n-1 do begin d:=a[i]-b[i]; if r[i]<>d then Halt(2); end;

  for i:=0 to n-1 do r[i]:=a[i]*b[i];            { arr_arr * }
  for i:=0 to n-1 do begin d:=a[i]*b[i]; if r[i]<>d then Halt(3); end;

  for i:=0 to n-1 do r[i]:=a[i]*s;               { arr_scalar b*s }
  for i:=0 to n-1 do begin d:=a[i]*s; if r[i]<>d then Halt(4); end;

  for i:=0 to n-1 do r[i]:=s-a[i];               { scalar-left s-b (non-comm.) }
  for i:=0 to n-1 do begin d:=s-a[i]; if r[i]<>d then Halt(5); end;

  for i:=0 to n-1 do r[i]:=a[i]*2.5;             { constant literal operand }
  for i:=0 to n-1 do begin d:=a[i]*2.5; if r[i]<>d then Halt(6); end;

  for i:=0 to n-1 do r[i]:=a[i];                 { copy }
  for i:=0 to n-1 do if r[i]<>a[i] then Halt(7);
end;

procedure workd(n: longint; s: double);
var a,b,r: array of double; i: longint; d: double;
begin
  SetLength(a,n); SetLength(b,n); SetLength(r,n);
  for i:=0 to n-1 do begin a[i]:=i*1.5-3.25; b[i]:=i*0.5+1.0; end;

  for i:=0 to n-1 do r[i]:=a[i]+b[i];
  for i:=0 to n-1 do begin d:=a[i]+b[i]; if r[i]<>d then Halt(11); end;

  for i:=0 to n-1 do r[i]:=a[i]-b[i];
  for i:=0 to n-1 do begin d:=a[i]-b[i]; if r[i]<>d then Halt(12); end;

  for i:=0 to n-1 do r[i]:=a[i]*b[i];
  for i:=0 to n-1 do begin d:=a[i]*b[i]; if r[i]<>d then Halt(13); end;

  for i:=0 to n-1 do r[i]:=a[i]*s;
  for i:=0 to n-1 do begin d:=a[i]*s; if r[i]<>d then Halt(14); end;

  for i:=0 to n-1 do r[i]:=s-a[i];
  for i:=0 to n-1 do begin d:=s-a[i]; if r[i]<>d then Halt(15); end;

  for i:=0 to n-1 do r[i]:=a[i];
  for i:=0 to n-1 do if r[i]<>a[i] then Halt(16);
end;

var k: longint;
begin
  for k:=0 to 17 do begin works(k, 3.25); workd(k, 3.25); end;
  works(100, -1.5);  workd(100, -1.5);
  works(1000, 0.75); workd(1000, 0.75);
end.
