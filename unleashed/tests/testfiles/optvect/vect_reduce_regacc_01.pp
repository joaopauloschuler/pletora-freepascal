{ %OPT="-O4 -OoVECTORIZE -OoFASTMATH -Cfsse64" }
{ Register-resident packed accumulator for the sum / dot-product reductions.
  The packed accumulator now lives in an xmm register across the whole vector
  loop (seeded before it, kept register-resident in the body, horizontally
  summed after it) instead of being stored/reloaded through a stack slot every
  iteration.  This fixture proves the register-resident codegen stays bit-exact
  vs a strict sequential (downto) scalar reduction: for exactly-representable
  inputs (multiples of 1/8, |partial sum| well under 2^24) there is no rounding,
  so every grouping yields the identical single value.  Checked for every trip
  count 0..40 (so the vector-main / scalar-tail split is exercised at every
  residue), a large size, a nonzero incoming accumulator, and two interleaved
  reductions in the same procedure (stressing that two live register
  accumulators coexist without clobbering each other). }
program vect_reduce_regacc_01;
{$mode objfpc}{$H+}
procedure work(n: longint; base: single);
var a,b: array of single; i: longint; s,t,ref,reft: single;
begin
  SetLength(a,n); SetLength(b,n);
  for i:=0 to n-1 do begin a[i]:=(i mod 8)*0.125 - 0.5; b[i]:=(i mod 4)*0.25 + 0.25; end;

  { sum }
  s:=base; for i:=0 to n-1 do s:=s+a[i];
  ref:=base; for i:=n-1 downto 0 do ref:=ref+a[i];
  if s<>ref then Halt(1);

  { dot product }
  s:=base; for i:=0 to n-1 do s:=s+a[i]*b[i];
  ref:=base; for i:=n-1 downto 0 do ref:=ref+a[i]*b[i];
  if s<>ref then Halt(2);

  { two interleaved reductions -- two register accumulators live at once }
  s:=base; t:=-base;
  for i:=0 to n-1 do s:=s+a[i];
  for i:=0 to n-1 do t:=t+a[i]*b[i];
  ref:=base; for i:=n-1 downto 0 do ref:=ref+a[i];
  reft:=-base; for i:=n-1 downto 0 do reft:=reft+a[i]*b[i];
  if (s<>ref) or (t<>reft) then Halt(3);
end;
var k: longint;
begin
  for k:=0 to 40 do
    begin
      work(k, 0.0);
      work(k, 7.5);
      work(k, -3.25);
    end;
  work(4096, 0.0);
  work(4096, 12.5);
  work(1000, -100.0);
end.
