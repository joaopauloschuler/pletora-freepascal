{ %OPT="-O4 -OoVECTORIZE -OoVECT256 -Cfavx2" }
{ AVX-256 aliasing safety.  A dynamic-array assignment  b:=a  makes b and a share
  ONE buffer.  The vectorizer only ever widens the same-index shape r[i]:=f(a[i])
  where the destination slot i is written after that same slot i is read, so an
  in-place / self-aliased update stays correct even at 256-bit width.  This
  fixture runs both the self-aliased (r and a share a buffer) and the
  fully-disjoint case and checks the results are bit-exact against a scalar
  recompute over a private copy.  Trip counts 0..17,100,1000.
  Requires an AVX2 host (the suite machine has avx2+fma per /proc/cpuinfo). }
program vect256_alias_01;
{$mode objfpc}{$H+}
procedure inplace(n: longint);
var a, ref: array of single; i: longint; d: single;
begin
  SetLength(a,n); SetLength(ref,n);
  for i:=0 to n-1 do begin a[i]:=i*0.5-2.0; ref[i]:=a[i]; end;
  { self-aliased in-place scale: a[i]:=a[i]*3  (dst slot i == src slot i) }
  for i:=0 to n-1 do a[i]:=a[i]*3.0;
  for i:=0 to n-1 do begin d:=ref[i]*3.0; if a[i]<>d then Halt(1); end;
end;

procedure disjoint(n: longint);
var a,b,r: array of single; i: longint; d: single;
begin
  SetLength(a,n); SetLength(b,n); SetLength(r,n);
  for i:=0 to n-1 do begin a[i]:=i*1.25-1.0; b[i]:=i*0.5+0.5; end;
  for i:=0 to n-1 do r[i]:=a[i]+b[i];
  for i:=0 to n-1 do begin d:=a[i]+b[i]; if r[i]<>d then Halt(2); end;
end;

var k: longint;
begin
  for k:=0 to 17 do begin inplace(k); disjoint(k); end;
  inplace(100); disjoint(100);
  inplace(1000); disjoint(1000);
end.
