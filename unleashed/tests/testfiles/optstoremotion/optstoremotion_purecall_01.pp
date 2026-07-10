{ %OPT=-O4 -OoPURE }
{ -OoPURE loop-pass fence relaxation for -OoSTOREMOTION. The pass promotes an
  invariant-address global to a register for a loop's duration, and required the
  ENTIRE loop node to be call-free because "a call could read/write the global".
  A call whose target -OoPURE proved CONST reads and writes NO memory, is side-
  effect free and non-trapping, so it can neither observe nor clobber the
  promoted global and can never raise before the post-loop store -- promotion
  across it is sound. A PURE (global-reading) call must still DECLINE promotion
  (it could read the promoted global's stale in-memory copy while the live value
  sits in the register), as must an impure call.

  Promotion is a pure relocation of memory traffic: it must never change any
  observable result. Every kernel is checked against a hand-computed compile-time
  constant. Halt(nonzero)=failure. }
program optstoremotion_purecall_01;
{$mode objfpc}{$H+}

var
  g: longint;
  gseen: longint = 0;   { written by the impure helper }

{ noinline getter keeps g memory-resident so promotion is observable at all }
function peek: longint; noinline; begin peek := g; end;

{ CONST: reads/writes no memory -> promotion across it is allowed }
function sq(x: longint): longint; noinline; begin sq := x*x; end;

{ PURE: reads a global but writes nothing -> promotion must be declined }
function preads(x: longint): longint; noinline; begin preads := gseen + x; end;

{ IMPURE: writes a global -> promotion must be declined }
function impure(x: longint): longint; noinline; begin gseen := gseen + x; impure := x; end;

{ const call in the loop -> g promotable with -OoPURE }
procedure acc_const(n: longint); noinline;
var i: longint;
begin
  for i := 1 to n do
    g := g + sq(i);
end;

{ pure (global-reading) call -> declined }
procedure acc_pure(n: longint); noinline;
var i: longint;
begin
  for i := 1 to n do
    g := g + preads(i);
end;

{ impure call -> declined }
procedure acc_impure(n: longint); noinline;
var i: longint;
begin
  for i := 1 to n do
    g := g + impure(i);
end;

begin
  { sum of squares 1..5 = 55 ;  1..0 = 0 (zero-trip) }
  g := 10; acc_const(5);  if peek <> 65 then Halt(1);
  g := 10; acc_const(0);  if peek <> 10 then Halt(2);
  g := 3;  acc_const(1);  if peek <> 4 then Halt(3);
  g := 0;  acc_const(100);if peek <> 338350 then Halt(4);

  { pure-call kernel: preads(i)=gseen+i, gseen stays 0 -> adds sum 1..6 = 21 }
  gseen := 0; g := 0; acc_pure(6);  if peek <> 21 then Halt(5);
  gseen := 0; g := 0; acc_pure(0);  if peek <> 0 then Halt(6);

  { impure-call kernel: impure(i)=i and bumps gseen; g gets sum 1..5 = 15 }
  gseen := 0; g := 0; acc_impure(5);
  if (peek <> 15) or (gseen <> 15) then Halt(7);

  Halt(0);
end.
