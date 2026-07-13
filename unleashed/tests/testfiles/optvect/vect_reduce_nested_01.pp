{ %OPT="-O4 -OoVECTORIZE -OoFASTMATH -Cfsse64" }
{ Nested-reduction autovectorization: a sum / dot reduction that is the INNER
  loop of an enclosing counted for-loop (the dense-layer `for row do (dot over
  cols)` shape) must vectorize just like a top-level reduction.  Before the
  loop-pass driver fix the callback stopped recursing after visiting the OUTER
  for-node, so the inner reduction loop was never handed to the recognizer and
  stayed scalar; now it packs 4-wide with a scalar tail.

  Correctness is checked against a strictly-sequential scalar reference computed
  with a DESCENDING (downto) inner loop, which neither the vectorizer nor
  -OoREASSOC touch.  For exactly-representable inputs (multiples of 1/8, partial
  sums well under 2^24) there is no rounding, so the reassociated packed grouping
  yields the bit-identical single value.  Exercised across every inner trip count
  0..40 (all tail residues) and a large size, for both matrix*vector (dot) and a
  plain row-sum reduction. }
program vect_reduce_nested_01;
{$mode objfpc}{$H+}
type TS = array of single;

procedure run(rows, cols: longint);
var
  m : array of TS;
  v, r, ref, rowarr : TS;
  row, col : longint;
  s, t : single;
begin
  SetLength(m, rows);
  SetLength(v, cols);
  SetLength(r, rows);
  SetLength(ref, rows);
  for col := 0 to cols-1 do
    v[col] := (col mod 4)*0.25 + 0.25;
  for row := 0 to rows-1 do
    begin
      SetLength(m[row], cols);
      for col := 0 to cols-1 do
        m[row][col] := ((row+col) mod 8)*0.125 - 0.5;
    end;

  { matrix * vector: inner dot over cols, nested in the outer row loop.  The row
    is hoisted into a simple local (the neural-api row-pointer idiom) so the
    inner array bases are plain non-aliased variables. }
  for row := 0 to rows-1 do
    begin
      s := 0;
      rowarr := m[row];
      for col := 0 to cols-1 do
        s := s + rowarr[col]*v[col];
      r[row] := s;
    end;
  { scalar reference: descending inner loop stays a strict serial reduction }
  for row := 0 to rows-1 do
    begin
      t := 0;
      for col := cols-1 downto 0 do
        t := t + m[row][col]*v[col];
      ref[row] := t;
    end;
  for row := 0 to rows-1 do
    if r[row] <> ref[row] then Halt(1);

  { plain row-sum reduction, also nested in the outer row loop }
  for row := 0 to rows-1 do
    begin
      s := 0;
      rowarr := m[row];
      for col := 0 to cols-1 do
        s := s + rowarr[col];
      r[row] := s;
    end;
  for row := 0 to rows-1 do
    begin
      t := 0;
      for col := cols-1 downto 0 do
        t := t + m[row][col];
      ref[row] := t;
    end;
  for row := 0 to rows-1 do
    if r[row] <> ref[row] then Halt(2);
end;

var k : longint;
begin
  { every inner trip count 0..40 exercises all tail residues; a couple of rows
    so the outer loop really iterates over multiple nested reductions }
  for k := 0 to 40 do
    run(3, k);
  run(5, 4096);
  run(1, 1000);
  Writeln('ok');
end.
