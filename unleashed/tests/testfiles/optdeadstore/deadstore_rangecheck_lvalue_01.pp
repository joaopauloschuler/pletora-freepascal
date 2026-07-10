{ %OPT="-O3 -Cr -Co -Oodeadstore" }
{ Regression: -Oodeadstore x range-checking (-Cr) lvalue-store miscompile.

  Enabling -Oodeadstore is the ONLY thing that runs the "normalize" tree pass
  (opttree.pas, invoked from psub before dead-store elimination). Under -Cr the
  write target of an assignment -- e.g.  a[i]  -- is lowered into a block
  expression whose result IS the target lvalue ("begin <rangecheck i>; a[i] end",
  expectloc LOC_REFERENCE). normalize's block-expression hoisting used to treat
  that block as an ordinary rvalue: it rewrote the block's final expression into
  "temp := a[i]" (a READ of the target) and replaced the block with a temp ref,
  so the assignment degenerated into "temp := <rhs>" and the real store to a[i]
  was silently dropped. The array element kept its previous value -> wrong result.

  The fix teaches normalize that the LHS of an assignment is a write target: a
  block-typed LHS is left exactly as codegen expects it and only the RHS is
  hoisted. This test forces -O3 -Cr -Co -Oodeadstore (so normalize runs with the
  range-check-wrapped stores present) and checks that range-checked element
  stores into a var open-array parameter, a dynamic array and a record field are
  actually performed, over several trip counts, matching a straightforward
  reference. It fails before the fix (stores dropped -> stale values) and passes
  after. }
program deadstore_rangecheck_lvalue_01;
{$mode objfpc}{$H+}

type
  TRec = record x: double; tag: longint; end;

function dval(i: longint): double; begin dval := i*1.25 - 0.5; end;

{ open-array var parameter: the exact shape that miscompiled }
procedure fill_open(var a: array of double; n: longint);
var i: longint;
begin
  for i := 0 to n-1 do
    a[i] := dval(i);
end;

{ dynamic array by reference }
procedure fill_dyn(var a: array of TRec; n: longint);
var i: longint;
begin
  for i := 0 to n-1 do
    begin
      a[i].x := dval(i) + 100.0;
      a[i].tag := i*7 - 3;
    end;
end;

var
  a: array of double;
  r: array of TRec;
  i, n: longint;
begin
  for n := 0 to 9 do
    begin
      setlength(a, n);
      setlength(r, n);
      { seed with a sentinel so a dropped store is detectable }
      for i := 0 to n-1 do
        begin
          a[i] := -999.0;
          r[i].x := -999.0;
          r[i].tag := -999;
        end;

      fill_open(a, n);
      fill_dyn(r, n);

      for i := 0 to n-1 do
        begin
          if a[i] <> dval(i) then Halt(1);
          if r[i].x <> dval(i) + 100.0 then Halt(2);
          if r[i].tag <> i*7 - 3 then Halt(3);
        end;
    end;
  Halt(0);
end.
