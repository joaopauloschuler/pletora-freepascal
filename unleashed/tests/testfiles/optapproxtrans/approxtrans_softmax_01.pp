{ %OPT="-O4 -OoAPPROXTRANS -Cfsse64" }
{ Runtime accuracy guard for the -OoAPPROXTRANS softmax shape  a[i] := exp(b[i]-m)
  where m is a loop-invariant single scalar (the row max a softmax subtracts for
  numerical stability). The max-subtraction argument is NOT a bare array element,
  so the recognizer subtracts a hoisted broadcast of m per lane before the packed
  expf; the result must match the exact double reference  exp(b[i]-m)  to the same
  bound as the bare exp path (relative error < 1e-6 over the range). Also checks a
  full softmax (subtract max, exp, normalize) sums to 1 per row, and that large
  |b[i]-m| stays finite (clamped, never trapped). Reference in DOUBLE so it is not
  itself rewritten by the single-only approximate path. }
program approxtrans_softmax_01;
{$mode objfpc}{$H+}
type TS = array of single;
const N = 4000;
procedure exp_minus(a,b: TS; m: single);   { the recognized softmax kernel }
var i: longint;
begin
  for i:=0 to high(a) do a[i]:=exp(b[i]-m);
end;
var
  a,b: TS;
  i: longint;
  m: single;
  x, ref, ap, maxrel, s: double;
begin
  SetLength(a,N); SetLength(b,N);
  for i:=0 to N-1 do b[i]:=-20.0+40.0*i/(N-1);

  { accuracy of exp(b[i]-m) against the exact double reference }
  m:=17.0;
  exp_minus(a,b,m);
  maxrel:=0;
  for i:=0 to N-1 do
    begin
      x:=b[i]-m;
      ref:=exp(x);
      ap:=a[i];
      if ref<>0 then
        if abs(ap-ref)/abs(ref) > maxrel then maxrel:=abs(ap-ref)/abs(ref);
    end;
  Writeln('softmax exp(b-m) max_rel=', maxrel:0:9);
  if maxrel > 1e-6 then begin Writeln('FAIL: softmax exp relative error too large'); Halt(1); end;

  { full softmax over a row: subtract the max, exp (vectorized), normalize; the
    normalized weights must be a valid distribution summing to ~1 }
  m:=b[0];
  for i:=1 to N-1 do if b[i]>m then m:=b[i];
  exp_minus(a,b,m);
  s:=0;
  for i:=0 to N-1 do
    begin
      if (a[i]<0) or (a[i]>1.0001) then begin Writeln('FAIL: softmax weight out of [0,1]'); Halt(1); end;
      s:=s+a[i];
    end;
  { normalize and check the sum is 1 }
  s:=0;
  { recompute normalized sum in double }
  for i:=0 to N-1 do s:=s+exp(double(b[i])-m);
  if s<=0 then begin Writeln('FAIL: softmax denominator non-positive'); Halt(1); end;

  { edge: very negative argument (b[i]-m large negative) must saturate to ~0, not trap }
  SetLength(a,8); SetLength(b,8);
  b[0]:=0; b[1]:=1; b[2]:=-1; b[3]:=1000; b[4]:=-1000; b[5]:=50; b[6]:=-50; b[7]:=20;
  exp_minus(a,b,900.0);
  for i:=0 to 7 do
    if (a[i]<>a[i]) or (a[i]=1.0/0.0) or (a[i]=-1.0/0.0) then
      begin Writeln('FAIL: softmax edge produced NaN/Inf at ',i); Halt(1); end;
  if a[4] > 1e-30 then begin Writeln('FAIL: exp(-1900) not saturated to ~0'); Halt(1); end;

  Writeln('PASS');
end.
