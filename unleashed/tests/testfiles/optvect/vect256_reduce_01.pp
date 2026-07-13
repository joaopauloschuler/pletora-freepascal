{ %OPT="-O4 -OoVECTORIZE -OoVECT256 -OoFASTMATH -Cfavx2" }
{ AVX-256 (ymm) reduction vectorization (sum + dot product), single and double,
  with the packed-FMA (vfmadd231ps/pd) dot path on an AVX2 fputype.  Widening
  to 8/4 lanes plus a vextractf128 horizontal-reduction epilogue reorders the
  partial sums, so the data is chosen to be small exact integers whose every
  partial sum stays well under 2^24 -- the result is then EXACT regardless of
  the summation grouping, and can be compared for equality against an
  independent serial reference.  Trip counts 0..17 exercise every ymm tail
  residue (0..7 single, 0..3 double); 100 and 1000 the steady state.
  Requires an AVX2 host (the suite machine has avx2+fma per /proc/cpuinfo). }
program vect256_reduce_01;
{$mode objfpc}{$H+}
function esum(n: longint): double;
var i: longint; s: double;
begin s:=0; for i:=0 to n-1 do s:=s+((i and 3)+1); esum:=s; end;
function edot(n: longint): double;
var i: longint; s: double;
begin s:=0; for i:=0 to n-1 do s:=s+(((i and 3)+1)*((i mod 3)+1)); edot:=s; end;

function sums(n: longint): single;
var a: array of single; i: longint; s: single;
begin
  SetLength(a,n);
  for i:=0 to n-1 do a[i]:=(i and 3)+1;
  s:=0; for i:=0 to n-1 do s:=s+a[i]; sums:=s;
end;
function dots(n: longint): single;
var a,b: array of single; i: longint; s: single;
begin
  SetLength(a,n); SetLength(b,n);
  for i:=0 to n-1 do begin a[i]:=(i and 3)+1; b[i]:=(i mod 3)+1; end;
  s:=0; for i:=0 to n-1 do s:=s+a[i]*b[i]; dots:=s;
end;
function sumd(n: longint): double;
var a: array of double; i: longint; s: double;
begin
  SetLength(a,n);
  for i:=0 to n-1 do a[i]:=(i and 3)+1;
  s:=0; for i:=0 to n-1 do s:=s+a[i]; sumd:=s;
end;
function dotd(n: longint): double;
var a,b: array of double; i: longint; s: double;
begin
  SetLength(a,n); SetLength(b,n);
  for i:=0 to n-1 do begin a[i]:=(i and 3)+1; b[i]:=(i mod 3)+1; end;
  s:=0; for i:=0 to n-1 do s:=s+a[i]*b[i]; dotd:=s;
end;

procedure check(n: longint);
begin
  if sums(n)<>esum(n) then Halt(1);
  if dots(n)<>edot(n) then Halt(2);
  if sumd(n)<>esum(n) then Halt(3);
  if dotd(n)<>edot(n) then Halt(4);
end;

var k: longint;
begin
  for k:=0 to 17 do check(k);
  check(100); check(1000);
end.
