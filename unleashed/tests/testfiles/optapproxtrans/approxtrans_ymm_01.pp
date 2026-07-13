{ %OPT="-O4 -OoAPPROXTRANS -OoVECT256 -Cfavx2" }
{ Runtime accuracy guard for the -OoAPPROXTRANS AVX2 256-bit (ymm) path. With
  -OoVECT256 on an AVX2 fputype the inline packed expf widens from 128-bit (VL=4)
  to 256-bit ymm (VL=8) -- the 2^n exponent build (vpaddd+vpslld) is an AVX2
  256-bit integer op. The wider window must be numerically identical in bound to
  the 128-bit path: the SAME per-lane polynomial runs, only 8 lanes at a time, so
  the documented error bounds still hold (exp rel < 1e-6, sigmoid rel < 1e-5,
  tanh abs < 1e-5) and the scalar remainder tail (up to VL-1=7 iterations here)
  keeps the exact RTL call. A non-multiple-of-8 length (4001) exercises that
  ymm-width remainder tail. Reference is computed in DOUBLE so it is not itself
  rewritten by the single-only approximate path. This test only runs on hosts
  with AVX2 (the compile targets -Cfavx2); on a non-AVX2 host it would SIGILL,
  which the suite treats as a run failure -- acceptable for a fork whose CI host
  is AVX2-capable (see approxtrans_check.sh for the static gate). }
program approxtrans_ymm_01;
{$mode objfpc}{$H+}
uses math;
type TS = array of single;
const N = 4001;   { not a multiple of 8: exercises the ymm remainder tail }
procedure aexp(a,b: TS);
var i: longint;
begin for i:=0 to high(a) do a[i]:=exp(b[i]); end;
procedure asig(a,b: TS);
var i: longint;
begin for i:=0 to high(a) do a[i]:=1/(1+exp(-b[i])); end;
procedure atanh(a,b: TS);
var i: longint;
begin for i:=0 to high(a) do a[i]:=tanh(b[i]); end;
var
  a,b: TS;
  i: longint;
  x, ref, ap, maxrel, maxabs: double;
begin
  SetLength(a,N); SetLength(b,N);

  { exp over [-20,20] }
  for i:=0 to N-1 do b[i]:=-20.0+40.0*i/(N-1);
  aexp(a,b);
  maxrel:=0;
  for i:=0 to N-1 do
    begin
      x:=b[i]; ref:=exp(x); ap:=a[i];
      if ref<>0 then
        if abs(ap-ref)/abs(ref) > maxrel then maxrel:=abs(ap-ref)/abs(ref);
    end;
  Writeln('ymm exp max_rel=', maxrel:0:9);
  if maxrel > 1e-6 then begin Writeln('FAIL: ymm exp relative error too large'); Halt(1); end;

  { sigmoid over [-20,20] }
  asig(a,b);
  maxrel:=0;
  for i:=0 to N-1 do
    begin
      x:=b[i]; ref:=1/(1+exp(-x)); ap:=a[i];
      if (a[i]<0) or (a[i]>1) then begin Writeln('FAIL: ymm sigmoid out of [0,1]'); Halt(1); end;
      if ref<>0 then
        if abs(ap-ref)/abs(ref) > maxrel then maxrel:=abs(ap-ref)/abs(ref);
    end;
  Writeln('ymm sigmoid max_rel=', maxrel:0:9);
  if maxrel > 1e-5 then begin Writeln('FAIL: ymm sigmoid relative error too large'); Halt(1); end;

  { tanh over [-10,10] }
  for i:=0 to N-1 do b[i]:=-10.0+20.0*i/(N-1);
  atanh(a,b);
  maxabs:=0;
  for i:=0 to N-1 do
    begin
      x:=b[i]; ref:=tanh(x); ap:=a[i];
      if (a[i]<-1.0001) or (a[i]>1.0001) then begin Writeln('FAIL: ymm tanh out of [-1,1]'); Halt(1); end;
      if abs(ap-ref) > maxabs then maxabs:=abs(ap-ref);
    end;
  Writeln('ymm tanh max_abs=', maxabs:0:9);
  if maxabs > 1e-5 then begin Writeln('FAIL: ymm tanh absolute error too large'); Halt(1); end;

  Writeln('PASS');
end.
