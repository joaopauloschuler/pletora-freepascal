{ %OPT="-O4 -OoAPPROXTRANS -Cfsse64" }
{ Runtime accuracy guard for the -OoAPPROXTRANS sigmoid  1/(1+exp(-x))  and
  tanh(x) activations, both derived from the inline packed expf. Sigmoid is
  compared against the exact double reciprocal-logistic; tanh against the exact
  double tanh. Bounds: sigmoid worst-case relative error < 1e-5 over [-20,20];
  tanh worst-case ABSOLUTE error < 1e-5 over [-10,10] (the identity-based tanh
  loses a little relative precision near 0 where tanh(x)~x, but its absolute
  error stays tiny). Saturation at large |x| must stay in [-1,1] / [0,1]. }
program approxtrans_sigmoid_tanh_01;
{$mode objfpc}{$H+}
uses math;
type TS = array of single;
const N = 4000;
procedure sig(a,b: TS);
var i: longint;
begin for i:=0 to high(a) do a[i]:=1/(1+exp(-b[i])); end;
procedure tnh(a,b: TS);
var i: longint;
begin for i:=0 to high(a) do a[i]:=tanh(b[i]); end;
var
  a,b: TS;
  i: longint;
  x, ref, ap, maxrel, maxabs: double;
begin
  SetLength(a,N); SetLength(b,N);

  { sigmoid }
  for i:=0 to N-1 do b[i]:=-20.0+40.0*i/(N-1);
  sig(a,b);
  maxrel:=0;
  for i:=0 to N-1 do
    begin
      x:=b[i]; ref:=1/(1+exp(-x)); ap:=a[i];
      if (a[i]<0) or (a[i]>1) then begin Writeln('FAIL: sigmoid out of [0,1]'); Halt(1); end;
      if ref<>0 then
        if abs(ap-ref)/abs(ref) > maxrel then maxrel:=abs(ap-ref)/abs(ref);
    end;
  Writeln('sigmoid max_rel=', maxrel:0:9);
  if maxrel > 1e-5 then begin Writeln('FAIL: sigmoid relative error too large'); Halt(1); end;

  { tanh }
  for i:=0 to N-1 do b[i]:=-10.0+20.0*i/(N-1);
  tnh(a,b);
  maxabs:=0;
  for i:=0 to N-1 do
    begin
      x:=b[i]; ref:=tanh(x); ap:=a[i];
      if (a[i]<-1.0001) or (a[i]>1.0001) then begin Writeln('FAIL: tanh out of [-1,1]'); Halt(1); end;
      if abs(ap-ref) > maxabs then maxabs:=abs(ap-ref);
    end;
  Writeln('tanh max_abs=', maxabs:0:9);
  if maxabs > 1e-5 then begin Writeln('FAIL: tanh absolute error too large'); Halt(1); end;

  { saturation edges }
  SetLength(a,8); SetLength(b,8);
  b[0]:=50; b[1]:=-50; b[2]:=0; b[3]:=5; b[4]:=-5; b[5]:=1; b[6]:=-1; b[7]:=10;
  sig(a,b);
  if (a[0]<0.999) or (a[1]>0.001) then begin Writeln('FAIL: sigmoid saturation'); Halt(1); end;
  tnh(a,b);
  if (a[0]<0.999) or (a[1]>-0.999) then begin Writeln('FAIL: tanh saturation'); Halt(1); end;
  Writeln('PASS');
end.
