{ %OPT=-O4 -OoPURE -OoLICM }
{ -OoPURE nothrow attribute consumer in -OoLICM.

  A loop-invariant call to a routine proven MEM-PURE (writes no memory, may read
  globals) AND NOTHROW (cannot raise/trap) is hoisted into the loop preheader --
  even for a possibly zero-trip loop -- when the loop body writes no memory.  The
  nothrow bit (tracked INDEPENDENTLY of purity) supplies the "safe to speculate"
  guarantee; a mem-pure call that may still TRAP must NOT be hoisted.

  Correctness must hold whether or not the hoist fires:

    * nf() reads a global, writes nothing, cannot trap -> hoistable.  The sum is
      the same computed once-per-iteration or once-hoisted.

    * tf() reads the same global but divides by it (may trap).  In the SAFETY
      kernel the divisor is 0 and the loop is zero-trip, so tf is NEVER called at
      runtime -- but if the nothrow gate were missing and the compiler
      speculatively hoisted tf into the preheader, tf would execute once and
      divide by zero, crashing the program.  A clean run therefore proves tf was
      not hoisted.

  ParamCount (0 with no args) hides the trip counts from the optimizer so the
  loops are neither folded away nor proven non-zero-trip. Halt(nonzero)=failure. }
program licm_nothrow_01;
{$mode objfpc}{$H+}

var
  gv: longint;

{ MEM-PURE + NOTHROW: reads the global gv, writes nothing, cannot trap }
function nf(i: longint): longint;
begin
  nf := gv + i;
end;

{ MEM-PURE but MAY TRAP (integer division by gv): NOT nothrow }
function tf(i: longint): longint;
begin
  tf := (100 div gv) + i;
end;

{ hoistable kernel: locals only in the loop body (no memory write), so nf's
  global read is loop-invariant and the call may be lifted to the preheader }
function sum_nf(n, k: longint): longint;
var
  i, s: longint;
begin
  s := 0;
  for i := 1 to n do
    s := s + nf(k);
  sum_nf := s;
end;

{ safety kernel: a may-trap call in a zero-trip loop with a zero divisor. Must
  stay in the (never-entered) loop body -- hoisting it would divide by zero. }
function sum_tf(n, k: longint): longint;
var
  i, s: longint;
begin
  s := 0;
  for i := 1 to n do
    s := s + tf(k);
  sum_tf := s;
end;

var
  trips, zero: longint;
begin
  trips := ParamCount + 5;   { 5 at runtime, unknown at compile time }
  zero  := ParamCount;       { 0 at runtime }

  gv := 10;
  { 5 iterations of gv+7 = 5 * 17 = 85 }
  if sum_nf(trips, 7) <> 85 then
    Halt(1);

  gv := 0;                   { divisor zero: tf would trap if ever executed }
  { zero-trip loop: tf must not run (and must not have been hoisted) }
  if sum_tf(zero, 7) <> 0 then
    Halt(2);

  writeln('ok');
end.
