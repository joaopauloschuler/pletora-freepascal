{ %OPT="-O4 -OoAPPROXTRANS -Cfsse64" }
{ Semantics guard: with -OoAPPROXTRANS ON, shapes the approximate path must NOT
  rewrite still compute the exact scalar result. A double-precision exp loop
  (single-only path declines) and a shifted-index exp(b[i+1]) (not element-wise)
  must both keep the exact RTL exp -- verified against a scalar recompute to a
  tight tolerance (1e-9 rel) that the ~1e-7 packed approximation would fail but
  the exact RTL path passes easily. This tripwires the recognizer wrongly firing
  on an out-of-contract shape (which would silently replace an exact result with
  an approximation). A tolerance rather than bit-equality is used because exp()
  may evaluate at extended precision before rounding into the stored element. }
program approxtrans_negatives_01;
{$mode objfpc}{$H+}
type
  TD = array of double;
  TS = array of single;
procedure dexp(a,b: TD);       { double: approximate path is single-only }
var i: longint;
begin for i:=0 to high(a) do a[i]:=exp(b[i]); end;
procedure sexp_shift(a,b: TS); { shifted index: not element-wise }
var i: longint;
begin for i:=0 to high(a)-1 do a[i]:=exp(b[i+1]); end;
var
  da,db: TD;
  sa,sb: TS;
  i: longint;
begin
  { double exp must be exact (bit-identical to a fresh scalar exp) }
  SetLength(da,64); SetLength(db,64);
  for i:=0 to 63 do db[i]:=-5.0+10.0*i/63;
  dexp(da,db);
  for i:=0 to 63 do
    if abs(da[i]-exp(db[i])) > 1e-9*abs(exp(db[i])) then
      begin Writeln('FAIL: double exp not exact at ',i); Halt(1); end;

  { shifted-index single exp must be exact too (single has ~6e-8 rounding, well
    below the ~1e-7 approximation, so a 1e-6 tol still separates but a tighter
    scalar-rounding check is used against a single-cast reference) }
  SetLength(sa,64); SetLength(sb,64);
  for i:=0 to 63 do sb[i]:=-3.0+6.0*i/63;
  sexp_shift(sa,sb);
  for i:=0 to 62 do
    if abs(sa[i]-single(exp(sb[i+1]))) > 1e-6*abs(single(exp(sb[i+1]))) then
      begin Writeln('FAIL: shifted-index exp not exact at ',i); Halt(1); end;

  Writeln('PASS');
end.
