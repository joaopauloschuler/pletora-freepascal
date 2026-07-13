{ %OPT=-O4 -OoMODREF }
{ -OoMODREF per-location consumer in -OoLICM (modref_call_hoistable).

  A loop-invariant call to a routine -OoMODREF proves WRITES NO MEMORY, is
  NON-TRAPPING, and READS only an EXACT set of static variables (never through a
  by-ref parameter) is hoisted into the preheader even when the loop body DOES
  write memory -- provided the body writes none of the statics the call reads.
  Unlike the -OoPURE nothrow path this reaches routines -OoPURE cannot prove
  mem-pure (here rd/trd take the address of a local) and fires across a loop that
  writes an unrelated static.

  Correctness must hold whether or not the hoist fires:

    * rd() reads only static gB, writes nothing, cannot trap.  In sum_disjoint
      the loop writes gA (disjoint from gB) so rd(k) is loop-invariant and may be
      lifted; the once-hoisted and once-per-iteration results are identical.

    * in sum_conflict the loop writes gB itself, so rd(k) is NOT invariant: the
      per-static region scan must keep the call in the body.  A wrong hoist would
      freeze rd at its first value and change the sum.

    * trd() reads gB but divides by it (may trap).  In the SAFETY kernel gB is 0
      and the loop is zero-trip, so trd is never called; a speculative preheader
      hoist would divide by zero.  A clean run proves the non-trapping gate held.

  ParamCount hides the trip counts so the loops are neither folded nor proven
  non-zero-trip. Halt(nonzero)=failure. }
program licm_modref_01;
{$mode objfpc}{$H+}

var
  gA, gB: longint;

{ writes nothing, reads only static gB, cannot trap; @tt (addr of a local) makes
  -OoPURE reject it, so ONLY -OoMODREF can hoist }
function rd(x: longint): longint;
var
  tt: longint;
begin
  tt := gB * x;
  if @tt = nil then rd := 0 else rd := tt + 1;
end;

{ writes nothing, reads gB, but MAY TRAP (integer div by gB): non-trapping gate
  must reject the hoist }
function trd(x: longint): longint;
var
  tt: longint;
begin
  tt := (100 div gB) + x;
  if @tt = nil then trd := 0 else trd := tt;
end;

{ loop writes gA (disjoint from gB): rd(k) is loop-invariant, hoistable }
function sum_disjoint(n, k: longint): longint;
var
  i, s: longint;
begin
  s := 0;
  for i := 1 to n do
    begin
      gA := gA + i;
      s := s + rd(k);
    end;
  sum_disjoint := s;
end;

{ loop writes gB (the very static rd reads): the per-static region scan must keep
  the call in the body }
function sum_conflict(n, k: longint): longint;
var
  i, s: longint;
begin
  s := 0;
  for i := 1 to n do
    begin
      gB := gB + i;
      s := s + rd(k);
    end;
  sum_conflict := s;
end;

{ zero-trip loop with a may-trap call and gB=0: trd must NOT be hoisted }
function sum_trap(n, k: longint): longint;
var
  i, s: longint;
begin
  s := 0;
  for i := 1 to n do
    s := s + trd(k);
  sum_trap := s;
end;

var
  trips, zero: longint;
begin
  trips := ParamCount + 5;   { 5 at runtime }
  zero  := ParamCount;       { 0 at runtime }

  { disjoint: gB=3 constant, rd(4)=3*4+1=13, 5 iterations -> 65 }
  gA := 0; gB := 3;
  if sum_disjoint(trips, 4) <> 65 then
    Halt(1);

  { conflict: gB grows by i each iteration, rd(4)=gB*4+1 recomputed each time:
    17+25+37+53+73 = 205 }
  gB := 3;
  if sum_conflict(trips, 4) <> 205 then
    Halt(2);

  { trap safety: zero-trip, gB=0 -> trd never runs and must not be hoisted }
  gB := 0;
  if sum_trap(zero, 4) <> 0 then
    Halt(3);

  writeln('ok');
end.
