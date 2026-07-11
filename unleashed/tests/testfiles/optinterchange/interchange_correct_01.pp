{ %OPT="-O4 -OoLOOPINTERCHANGE" }
{ Loop interchange (-OoLOOPINTERCHANGE): a perfect two-deep counted nest whose
  inner loop strides a non-contiguous flat 2D index  a[i*W+j]  is reordered so
  the inner loop strides the row-contiguous dimension.  This must be numerically
  transparent: the *_fast versions (whose local dynamic-array counters are plain
  and so ARE interchanged) must equal the *_ref versions (whose loop counter is
  address-taken, which makes the pass decline them -- rangeelim_simple_var
  rejects an addr_taken counter -- so they run in the original order) for every
  trip-count combination, including the 0 / 1 / non-multiple edge cases where a
  zero-trip inner or outer loop is the interesting corner.  Two body shapes are
  exercised: an element-wise map  b[idx]:=f(a[idx])  (subset R, bit-exact for any
  type because same-cell writes are idempotent) and an integer sum-reduction
  s:=s+a[idx]  (subset S, exact under any grouping for integer accumulators). }
program interchange_correct_01;
{$mode objfpc}{$H+}

{ subset R -- element-wise map, column-major nest (inner i strides W): interchanged }
function map_fast(H, W: longint): int64;
var a, b: array of double; i, j: longint; s: int64;
begin
  SetLength(a, H*W+1); SetLength(b, H*W+1);
  for i := 0 to H*W-1 do a[i] := (i mod 13)*0.5 - 3.0;
  for i := 0 to H*W do b[i] := 999.0;
  for j := 0 to W-1 do
    for i := 0 to H-1 do
      b[i*W+j] := a[i*W+j]*2.0 + 1.0;
  s := 0;
  for i := 0 to H*W-1 do s := s + Round(b[i]*8.0);
  map_fast := s;
end;

{ same map but the counter is address-taken -> interchange declines -> reference }
function map_ref(H, W: longint): int64;
var a, b: array of double; i, j: longint; s: int64; p: pointer;
begin
  p := @j;
  SetLength(a, H*W+1); SetLength(b, H*W+1);
  for i := 0 to H*W-1 do a[i] := (i mod 13)*0.5 - 3.0;
  for i := 0 to H*W do b[i] := 999.0;
  for j := 0 to W-1 do
    for i := 0 to H-1 do
      b[i*W+j] := a[i*W+j]*2.0 + 1.0;
  s := 0;
  for i := 0 to H*W-1 do s := s + Round(b[i]*8.0);
  if p = nil then Halt(9);
  map_ref := s;
end;

{ subset S -- integer column-major sum reduction: interchanged }
function red_fast(H, W: longint): int64;
var a: array of longint; i, j: longint; s: int64;
begin
  SetLength(a, H*W+1);
  for i := 0 to H*W-1 do a[i] := (i mod 17)*3 - 20;
  s := 0;
  for j := 0 to W-1 do
    for i := 0 to H-1 do
      s := s + a[i*W+j];
  red_fast := s;
end;

function red_ref(H, W: longint): int64;
var a: array of longint; i, j: longint; s: int64; p: pointer;
begin
  p := @j;
  SetLength(a, H*W+1);
  for i := 0 to H*W-1 do a[i] := (i mod 17)*3 - 20;
  s := 0;
  for j := 0 to W-1 do
    for i := 0 to H-1 do
      s := s + a[i*W+j];
  if p = nil then Halt(9);
  red_ref := s;
end;

procedure check(H, W: longint);
begin
  if map_fast(H, W) <> map_ref(H, W) then Halt(1);
  if red_fast(H, W) <> red_ref(H, W) then Halt(2);
end;

var
  h, w: longint;
begin
  { edge trip counts: 0x0, 0xN, Nx0, 1x1, and non-multiple rectangles }
  check(0, 0);
  check(0, 5);
  check(5, 0);
  check(1, 1);
  check(1, 9);
  check(9, 1);
  check(2, 3);
  check(3, 2);
  check(7, 5);
  check(5, 7);
  { a broad sweep of small rectangles }
  for h := 0 to 11 do
    for w := 0 to 11 do
      check(h, w);
  Writeln('ok');
end.
