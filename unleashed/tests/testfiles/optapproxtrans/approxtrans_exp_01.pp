{ %OPT="-O4 -OoAPPROXTRANS -Cfsse64" }
{ Runtime accuracy guard for the -OoAPPROXTRANS vectorized approximate expf.
  The exp() activation loop over single arrays is lowered to an inline packed
  Cephes-style polynomial; here we assert its worst-case error against the exact
  RTL exp over a dense sweep of [-20,20] (the practical activation range) and
  check that clamped out-of-range / large-magnitude inputs stay finite and never
  raise (no FP overflow trap). The reference is computed in DOUBLE precision so
  it is NOT itself rewritten by the single-only approximate path. Bounds:
  worst-case relative error < 1e-6 across the range; edges finite. }
program approxtrans_exp_01;
{$mode objfpc}{$H+}
type TS = array of single;
const N = 4000;
procedure act(a,b: TS);
var i: longint;
begin
  for i:=0 to high(a) do a[i]:=exp(b[i]);
end;
var
  a,b: TS;
  i: longint;
  x, ref, ap, maxrel: double;
begin
  SetLength(a,N); SetLength(b,N);
  for i:=0 to N-1 do b[i]:=-20.0+40.0*i/(N-1);
  act(a,b);
  maxrel:=0;
  for i:=0 to N-1 do
    begin
      x:=b[i];
      ref:=exp(x);                 { exact double reference }
      ap:=a[i];
      if ref<>0 then
        if abs(ap-ref)/abs(ref) > maxrel then maxrel:=abs(ap-ref)/abs(ref);
    end;
  Writeln('exp max_rel=', maxrel:0:9);
  if maxrel > 1e-6 then
    begin Writeln('FAIL: exp relative error too large'); Halt(1); end;

  { edge inputs: must not trap and must stay finite/clamped }
  SetLength(a,8); SetLength(b,8);
  b[0]:=0; b[1]:=1000; b[2]:=-1000; b[3]:=88; b[4]:=-88; b[5]:=1; b[6]:=-1; b[7]:=20;
  act(a,b);
  for i:=0 to 7 do
    if (a[i]<>a[i]) or (a[i]=1.0/0.0) or (a[i]=-1.0/0.0) then    { NaN or +-Inf }
      begin Writeln('FAIL: exp edge produced NaN/Inf at ',i); Halt(1); end;
  if (a[0]<0.99) or (a[0]>1.01) then begin Writeln('FAIL: exp(0)<>1'); Halt(1); end;
  if a[2] > 1e-30 then begin Writeln('FAIL: exp(-1000) not saturated to ~0'); Halt(1); end;
  Writeln('PASS');
end.
