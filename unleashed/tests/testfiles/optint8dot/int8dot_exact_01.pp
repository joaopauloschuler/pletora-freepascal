{ %OPT="-O4 -OoINT8DOT -Cfsse64" }
{ -OoINT8DOT bit-exactness: the int8 quantized dot-product reduction
    s := s + a[i]*b[i]     (a,b : array of shortint;  s : longint)
  is lowered to a widening vpmaddwd MAC (sign-extend the shortint windows to
  16-bit, multiply-add adjacent pairs into 32-bit lanes, accumulate with vpaddd,
  horizontally sum after the loop).  The multiply is EXACT (a shortint fits in 16
  bits and each adjacent-pair product-sum fits in 32) and integer addition is
  associative/commutative modulo 2^32, so the packed partial-sum order is
  bit-identical to the wrapping scalar reference for ALL inputs.

  The ASCENDING (to) loop is the one the vectorizer rewrites; the DESCENDING
  (downto) loop is a strict sequential scalar oracle the vectorizer never touches
  (a negative step is not a recognizable vector loop).  Because the reduction is
  exact regardless of grouping, the two must agree bit-for-bit -- including the
  saturation-triggering extremes (all -128 => 16384 products) and a nonzero
  incoming seed near INT32 bounds that forces the accumulator to wrap.

  Swept over adversarial fills and the boundary trip counts 0,1,15,16,17,8191
  (below/at/above the 8- and 16-wide vector windows, and a large size). }
program int8dot_exact_01;
{$mode objfpc}{$H+}
{$Q-}{$R-}

type TB = array of shortint;

{ vectorized: ascending accumulate }
function dot_vec(const a,b: TB; n: longint; seed: longint): longint;
var i: longint; s: longint;
begin
  s:=seed;
  for i:=0 to n-1 do
    s:=s+a[i]*b[i];
  dot_vec:=s;
end;

{ scalar oracle: descending accumulate (never vectorized) }
function dot_ref(const a,b: TB; n: longint; seed: longint): longint;
var i: longint; s: longint;
begin
  s:=seed;
  for i:=n-1 downto 0 do
    s:=s+a[i]*b[i];
  dot_ref:=s;
end;

var
  a,b: TB;

{ fill kind selects an adversarial deterministic pattern }
procedure fill(n, kind: longint);
var i: longint;
begin
  SetLength(a,n); SetLength(b,n);
  for i:=0 to n-1 do
    case kind of
      0: begin a[i]:=-128; b[i]:=-128; end;           { extreme +16384 products }
      1: begin a[i]:= 127; b[i]:= 127; end;           { extreme +16129 products }
      2: begin a[i]:=-128; b[i]:= 127; end;           { extreme -16256 products }
      3: begin                                        { alternating signs }
           if odd(i) then a[i]:=-128 else a[i]:=127;
           if odd(i) then b[i]:=127  else b[i]:=-128;
         end;
      4: begin                                        { deterministic pseudo-random }
           a[i]:=shortint((i*73+11) and $ff);
           b[i]:=shortint((i*151+29) and $ff);
         end;
    else
      begin a[i]:=shortint(i and $ff); b[i]:=shortint((255-i) and $ff); end;
    end;
end;

const
  lengths: array[0..5] of longint = (0,1,15,16,17,8191);
  seeds:   array[0..3] of longint = (0, 12345, 2147483000, -2147483000);

var
  li, ki, si: longint;
  n: longint;

begin
  for li:=0 to High(lengths) do
    begin
      n:=lengths[li];
      for ki:=0 to 5 do
        begin
          fill(n, ki);
          for si:=0 to High(seeds) do
            if dot_vec(a,b,n,seeds[si]) <> dot_ref(a,b,n,seeds[si]) then
              begin
                Writeln('MISMATCH n=',n,' kind=',ki,' seed=',seeds[si],
                        ' vec=',dot_vec(a,b,n,seeds[si]),
                        ' ref=',dot_ref(a,b,n,seeds[si]));
                Halt(1);
              end;
        end;
    end;
  Writeln('OK');
end.
