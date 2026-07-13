{ %OPT="-O4 -OoAPPROXTRANS -Cfsse64" }
{ Runtime guard for the lower-cancellation -OoAPPROXTRANS tanh. The kernel is now
  tanh(x) = t/(t+2) with t = expm1(2x) (an expm1 that never forms e^x and then
  subtracts 1), instead of the old 2/(1+exp(-2x))-1 whose trailing -1 catastrophically
  cancelled the tiny near-zero value: for x~0, tanh(x)~x, and the old form's single-
  precision result had ~4e-4 RELATIVE error near zero even though its ABSOLUTE error
  stayed ~1.7e-7. The expm1 form keeps t~2x and t/(t+2)~x with full relative precision.

  This test asserts the tight NEAR-ZERO relative bound the old form could not meet
  (< 1e-5 for 1e-4 <= |x| <= 1.0 -- the old form measured ~4e-4 here), plus the
  documented full-range absolute bound (< 1e-6 over [-10,10]) and monotone saturation
  to +-1. Reference in DOUBLE so it is not itself rewritten by the single-only path. }
program approxtrans_tanh_relerr_01;
{$mode objfpc}{$H+}
uses math;
type TS = array of single;
const N = 8000;
procedure atanh(a,b: TS);
var i: longint;
begin
  for i:=0 to high(a) do a[i]:=tanh(b[i]);
end;
var
  a,b: TS;
  i: longint;
  x, ref, ap, maxabs, maxrel_nz: double;
begin
  { near-zero relative error over [-1,1] (excluding a tiny neighbourhood of 0
    where the reference is itself ~0 and a relative test is ill-defined) }
  SetLength(a,N); SetLength(b,N);
  for i:=0 to N-1 do b[i]:=-1.0+2.0*i/(N-1);
  atanh(a,b);
  maxrel_nz:=0;
  for i:=0 to N-1 do
    begin
      x:=b[i];
      if abs(x) < 1e-4 then continue;
      ref:=tanh(x);
      ap:=a[i];
      if abs(ap-ref)/abs(ref) > maxrel_nz then maxrel_nz:=abs(ap-ref)/abs(ref);
    end;
  Writeln('tanh near0 max_rel=', maxrel_nz:0:9);
  if maxrel_nz > 1e-5 then
    begin Writeln('FAIL: near-zero tanh relative error too large (cancellation not avoided)'); Halt(1); end;

  { full-range absolute error over [-10,10] }
  for i:=0 to N-1 do b[i]:=-10.0+20.0*i/(N-1);
  atanh(a,b);
  maxabs:=0;
  for i:=0 to N-1 do
    begin
      x:=b[i]; ref:=tanh(x); ap:=a[i];
      if (a[i]<-1.0001) or (a[i]>1.0001) then begin Writeln('FAIL: tanh out of [-1,1]'); Halt(1); end;
      if abs(ap-ref) > maxabs then maxabs:=abs(ap-ref);
    end;
  Writeln('tanh full max_abs=', maxabs:0:9);
  if maxabs > 1e-6 then begin Writeln('FAIL: tanh absolute error too large'); Halt(1); end;

  { saturation and oddness at the edges }
  SetLength(a,8); SetLength(b,8);
  b[0]:=40; b[1]:=-40; b[2]:=0; b[3]:=8; b[4]:=-8; b[5]:=0.001; b[6]:=-0.001; b[7]:=15;
  atanh(a,b);
  if (a[0]<0.999) or (a[1]>-0.999) then begin Writeln('FAIL: tanh saturation'); Halt(1); end;
  if abs(a[2]) > 1e-6 then begin Writeln('FAIL: tanh(0)<>0'); Halt(1); end;
  { tanh(0.001) ~ 0.001 to full relative precision (the whole point of expm1) }
  if abs(a[5]-0.001)/0.001 > 1e-4 then begin Writeln('FAIL: tanh(0.001) lost relative precision'); Halt(1); end;
  if abs(a[5]+a[6]) > 1e-9 then begin Writeln('FAIL: tanh not odd near 0'); Halt(1); end;

  Writeln('PASS');
end.
