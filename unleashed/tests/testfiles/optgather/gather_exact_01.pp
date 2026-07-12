{ %OPT="-O4 -OoGATHER -Cfavx2" }
{ -OoGATHER bit-exactness: the single-precision indexed sum reduction
    s := s + a[idx[i]]     (a : array of single ; idx : array of longint)
  is lowered to an AVX2 vgatherdps that gathers a[idx[i..i+VF-1]] into a packed
  register-resident partial sum (VF=4 xmm / VF=8 ymm), horizontally summed after
  the loop.  Because the packed partial sums reorder the floating-point adds
  (exactly like the -OoREASSOC reduction it shares its fast-math gate with), the
  result is bit-identical to a sequential scalar reduction ONLY when the adds do
  not round -- so this fixture fills a[] with SMALL INTEGER values and keeps the
  running sums below 2^24, where every partial sum is represented exactly in a
  single and the result is independent of summation order.

  The ASCENDING (to) loop is the one the vectorizer rewrites into the gather; the
  DESCENDING (downto) loop is a strict sequential scalar oracle the vectorizer
  never touches (a negative step is not a recognizable vector loop).  The gathered
  addresses a[idx[i]] are exactly those the scalar loop reads, lane for lane, so
  with exact arithmetic the two must agree bit-for-bit.

  The index array is filled with adversarial patterns -- all pointing at index 0,
  all at the last index n-1, an alternating boundary 0/n-1 pattern, a strided
  pattern with duplicates, and two pseudo-random fills including duplicates and
  both boundaries -- swept over the trip counts 0,1,3,4,5,7,8,9,63,64,65,8191
  (below/at/above the 4- and 8-wide gather windows, and a large size). }
program gather_exact_01;
{$mode objfpc}{$H+}
{$Q-}{$R-}

type
  TS = array of single;
  TI = array of longint;

{ vectorized: ascending indexed accumulate (the gather) }
function gsum_vec(a: TS; idx: TI; n: longint): single;
var i: longint; s: single;
begin
  s:=0;
  for i:=0 to n-1 do
    s:=s+a[idx[i]];
  gsum_vec:=s;
end;

{ scalar oracle: descending accumulate (never vectorized) }
function gsum_ref(a: TS; idx: TI; n: longint): single;
var i: longint; s: single;
begin
  s:=0;
  for i:=n-1 downto 0 do
    s:=s+a[idx[i]];
  gsum_ref:=s;
end;

{ a[k] := small exact-in-float integer value (0..7), so every partial sum stays
  an exactly-representable integer and the reduction is order-independent }
procedure fill_vals(var a: TS; n: longint);
var k: longint;
begin
  SetLength(a,n);
  for k:=0 to n-1 do
    a[k]:=single((k*3+1) and 7);
end;

{ fill idx[0..n-1] with valid indices into 0..n-1 for pattern `kind` }
procedure fill_idx(var idx: TI; n: longint; kind: longint);
var i: longint; r: longword;
begin
  SetLength(idx,n);
  if n=0 then exit;
  r:=longword(2166136261);
  for i:=0 to n-1 do
    case kind of
      0: idx[i]:=0;                                   { all -> first }
      1: idx[i]:=n-1;                                 { all -> last }
      2: if (i and 1)=0 then idx[i]:=0 else idx[i]:=n-1;  { alternating boundaries }
      3: idx[i]:=(i*7) mod n;                         { strided, duplicates }
      else
        begin
          { xorshift-ish pseudo-random with duplicates and both boundaries }
          r:=r xor (r shl 13); r:=r xor (r shr 17); r:=r xor (r shl 5);
          if (i mod 11)=0 then idx[i]:=0
          else if (i mod 13)=0 then idx[i]:=n-1
          else idx[i]:=longint(r mod longword(n));
        end;
    end;
end;

var
  a: TS;
  idx: TI;
  lengths: array[0..11] of longint = (0,1,3,4,5,7,8,9,63,64,65,8191);
  li, kind: longint;
  n: longint;
  rv, rr: single;
  bad: boolean;
begin
  bad:=false;
  for li:=0 to High(lengths) do
    begin
      n:=lengths[li];
      fill_vals(a,n);
      for kind:=0 to 5 do
        begin
          fill_idx(idx,n,kind);
          rv:=gsum_vec(a,idx,n);
          rr:=gsum_ref(a,idx,n);
          if rv<>rr then
            begin
              Writeln('MISMATCH n=',n,' kind=',kind,' vec=',rv:0:1,' ref=',rr:0:1);
              bad:=true;
            end;
        end;
    end;
  if bad then
    begin
      Writeln('FAIL');
      Halt(1);
    end;
  Writeln('OK');
end.
