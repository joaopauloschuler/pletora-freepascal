{ %OPT="-O4 -OoLOOPTILE" }
{ Loop tiling / cache blocking (-OoLOOPTILE): a perfect three-deep counted
  matmul-shaped reduction nest  c[i*N+j] := c[i*N+j] + a[i*K+k]*b[k*N+j]  is
  blocked into cache-sized tiles over the two output loops i and j, with the point
  loops reordered i/k/j (j and k interchanged) so the inner loop strides the
  contiguous dimension.  This must be numerically transparent: the *_fast versions
  (whose local dynamic-array counters are plain and so ARE tiled) must equal the
  *_ref versions (whose loop counter is address-taken, which makes the pass decline
  them -- rangeelim_simple_var rejects an addr_taken counter -- so they run in the
  original i/j/k order) for every size combination, INCLUDING the awkward
  non-multiple sizes 97x63x41 / 65x1x130 / 3x128x2 that exercise the remainder
  tiles (a tile edge not dividing the loop bound) and the 0/1 edge trip counts.

  Two element types are exercised: an integer accumulator (exact under any
  grouping, so tiling is bit-exact regardless of index injectivity) and a single-
  precision float accumulator (bit-exact here because the write index i*N+j is
  injective over the (i,j) rectangle -- distinct output cells never alias -- so no
  cell's k-reduction is ever reordered; the j<->k interchange keeps each cell's
  k-sum in the original increasing-k order). }
program looptile_correct_01;
{$mode objfpc}{$H+}

{ integer matmul, plain counters -> tiled }
function imm_fast(rows, cols, inner: longint): int64;
var a, b, c: array of longint; i, j, k: longint; s: int64;
begin
  SetLength(a, rows*inner+1); SetLength(b, inner*cols+1); SetLength(c, rows*cols+1);
  for i := 0 to rows*inner-1 do a[i] := (i mod 13) - 6;
  for i := 0 to inner*cols-1 do b[i] := (i mod 11) - 5;
  for i := 0 to rows*cols-1 do c[i] := 0;
  for i := 0 to rows-1 do
    for j := 0 to cols-1 do
      for k := 0 to inner-1 do
        c[i*cols+j] := c[i*cols+j] + a[i*inner+k]*b[k*cols+j];
  s := 0;
  for i := 0 to rows*cols-1 do s := s + c[i]*(i+1);
  imm_fast := s;
end;

{ same, but a counter is address-taken -> the pass declines -> reference order }
function imm_ref(rows, cols, inner: longint): int64;
var a, b, c: array of longint; i, j, k: longint; s: int64; p: pointer;
begin
  p := @j;
  SetLength(a, rows*inner+1); SetLength(b, inner*cols+1); SetLength(c, rows*cols+1);
  for i := 0 to rows*inner-1 do a[i] := (i mod 13) - 6;
  for i := 0 to inner*cols-1 do b[i] := (i mod 11) - 5;
  for i := 0 to rows*cols-1 do c[i] := 0;
  for i := 0 to rows-1 do
    for j := 0 to cols-1 do
      for k := 0 to inner-1 do
        c[i*cols+j] := c[i*cols+j] + a[i*inner+k]*b[k*cols+j];
  s := 0;
  for i := 0 to rows*cols-1 do s := s + c[i]*(i+1);
  if p = nil then Halt(9);
  imm_ref := s;
end;

{ single-precision matmul, plain counters -> tiled (injective index -> bit-exact) }
function fmm_fast(rows, cols, inner: longint): int64;
var a, b, c: array of single; i, j, k: longint; s: int64;
begin
  SetLength(a, rows*inner+1); SetLength(b, inner*cols+1); SetLength(c, rows*cols+1);
  for i := 0 to rows*inner-1 do a[i] := ((i mod 13) - 6)*0.5;
  for i := 0 to inner*cols-1 do b[i] := ((i mod 11) - 5)*0.25;
  for i := 0 to rows*cols-1 do c[i] := 0.0;
  for i := 0 to rows-1 do
    for j := 0 to cols-1 do
      for k := 0 to inner-1 do
        c[i*cols+j] := c[i*cols+j] + a[i*inner+k]*b[k*cols+j];
  s := 0;
  for i := 0 to rows*cols-1 do s := s + Round(c[i]*64.0)*(i+1);
  fmm_fast := s;
end;

function fmm_ref(rows, cols, inner: longint): int64;
var a, b, c: array of single; i, j, k: longint; s: int64; p: pointer;
begin
  p := @j;
  SetLength(a, rows*inner+1); SetLength(b, inner*cols+1); SetLength(c, rows*cols+1);
  for i := 0 to rows*inner-1 do a[i] := ((i mod 13) - 6)*0.5;
  for i := 0 to inner*cols-1 do b[i] := ((i mod 11) - 5)*0.25;
  for i := 0 to rows*cols-1 do c[i] := 0.0;
  for i := 0 to rows-1 do
    for j := 0 to cols-1 do
      for k := 0 to inner-1 do
        c[i*cols+j] := c[i*cols+j] + a[i*inner+k]*b[k*cols+j];
  s := 0;
  for i := 0 to rows*cols-1 do s := s + Round(c[i]*64.0)*(i+1);
  if p = nil then Halt(9);
  fmm_ref := s;
end;

procedure check(rows, cols, inner: longint);
begin
  if imm_fast(rows, cols, inner) <> imm_ref(rows, cols, inner) then Halt(1);
  if fmm_fast(rows, cols, inner) <> fmm_ref(rows, cols, inner) then Halt(2);
end;

var
  r, cc: longint;
begin
  { awkward non-multiple sizes (remainder tiles) and edge trip counts }
  check(97, 63, 41);
  check(65, 1, 130);
  check(3, 128, 2);
  check(64, 64, 64);
  check(0, 0, 0);
  check(0, 5, 5);
  check(5, 0, 5);
  check(5, 5, 0);
  check(1, 1, 1);
  check(1, 130, 1);
  check(130, 1, 1);
  { a small sweep spanning the 64-iteration tile edge }
  for r := 1 to 5 do
    for cc := 62 to 67 do
      check(r, cc, 3);
  Writeln('ok');
end.
