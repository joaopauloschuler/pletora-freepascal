{ %OPT="-O4 -OoVECTORIZE -OoFASTMATH -Cfavx2" }
{ Packed-FMA dot-product reduction on an FMA-capable target (-Cfavx2).  Under
  the SAME fast-math/FMA gate the scalar  a*b+c -> fma()  contraction uses, the
  vectorized dot product fuses its packed multiply-add into a single
  vfmadd231ps/pd instead of vmulps+vaddps.  A fused multiply-add rounds ONCE
  (the product is not rounded before the add), so its result differs from a
  separate mul-then-add -- exactly the license fast-math already grants.  This
  test therefore does NOT assert bit-exactness against the scalar reduction;
  instead it uses NON-exactly-representable inputs (so rounding genuinely
  happens) and checks the single-precision packed result agrees with a
  double-precision sequential reference within a relative tolerance.  The
  presence of the vfmadd instruction itself is asserted by
  unleashed/tests/vectorize_reduce_check.sh. }
program vect_reduce_fma_01;
{$mode objfpc}{$H+}
function reldiff(x: single; ref: double): double;
var d: double;
begin
  d:=abs(x-ref);
  reldiff:=d/(abs(ref)+1.0);
end;

procedure work(n: longint; base: single);
var a,b: array of single; i: longint; s: single; ref: double;
begin
  SetLength(a,n); SetLength(b,n);
  for i:=0 to n-1 do begin a[i]:=((i mod 17)+1)*0.1; b[i]:=((i mod 13)+1)*0.1; end;

  { single-precision dot -- vectorizes into a packed vfmadd231ps reduction }
  s:=base; for i:=0 to n-1 do s:=s+a[i]*b[i];
  { double-precision sequential reference }
  ref:=base; for i:=0 to n-1 do ref:=ref+double(a[i])*double(b[i]);
  if reldiff(s,ref)>1e-3 then Halt(1);

  { commuted addend order  s := a[i]*b[i] + s  -- same fused shape }
  s:=base; for i:=0 to n-1 do s:=a[i]*b[i]+s;
  if reldiff(s,ref)>1e-3 then Halt(2);
end;

procedure workd(n: longint; base: double);
var a,b: array of double; i: longint; s: double; ref: double;
begin
  SetLength(a,n); SetLength(b,n);
  for i:=0 to n-1 do begin a[i]:=((i mod 17)+1)*0.1; b[i]:=((i mod 13)+1)*0.1; end;

  { double-precision dot -- vectorizes into a packed vfmadd231pd reduction }
  s:=base; for i:=0 to n-1 do s:=s+a[i]*b[i];
  ref:=base; for i:=n-1 downto 0 do ref:=ref+a[i]*b[i];
  { double fma vs a strict sequential double reduction: both round, but the
    magnitudes are small so a modest relative tolerance holds }
  if abs(s-ref)/(abs(ref)+1.0)>1e-9 then Halt(3);
end;

var k: longint;
begin
  for k:=0 to 20 do begin work(k,0.0); work(k,6.25); workd(k,0.0); workd(k,6.25); end;
  work(2049,-8.0);
  workd(2049,-8.0);
end.
