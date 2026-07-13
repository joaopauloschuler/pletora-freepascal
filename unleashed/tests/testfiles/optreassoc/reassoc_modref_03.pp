{ %OPT=-O4 -OoMODREF -OoREASSOC }
{ -OoMODREF write-DISJOINT generalisation of the -OoREASSOC reduction-addend
  fence (loop_is_modref_reorderable_call).

  A reduction  acc := acc + f(i)  is split into K partial accumulators by copying
  the addend (with a shifted counter) K times.  A call in the addend used to be
  admitted only when it wrote NO memory (pure/const, or -OoMODREF write-free).
  -OoMODREF now also admits a call that WRITES memory, provided its summary is
  EXACT (per-formal by-ref mask + per-static set both complete) and it cannot
  trap.  Soundness: the transform copies the addend as an indivisible blob and
  evaluates the copies in counter order, so the count and order of every side
  effect are preserved exactly and no memory access is reordered relative to
  another -- only the summation of the (bit-identical) addend values is regrouped
  (see loop_is_modref_reorderable_call's note).

  Here f WRITES the global gtouch and READS it back in the same call.  Call k
  (k=0..n, evaluated in counter order) makes gtouch = k+1 and returns
  k + (k+1) = 2k+1, so the reduction over 0..100 is sum(2k+1) = 10201 and gtouch
  ends at 101 -- independent of how the additions are grouped.  A wrong split
  (reordering the writing calls) would change gtouch's progression and the sum.

  ParamCount hides the trip count.  Halt(nonzero)=failure. }
program reassoc_modref_03;
{$mode objfpc}{$H+}

var
  gtouch: longint;

{ writes gtouch and reads it back: an exact-summary, non-trapping WRITING call }
function f(i: longint): longint;
begin
  gtouch := gtouch + 1;
  f := i + gtouch;
end;

function reduce(n: longint): longint;
var
  i, acc: longint;
begin
  acc := 0;
  for i := 0 to n do
    acc := acc + f(i);
  reduce := acc;
end;

var
  trips: longint;
begin
  trips := ParamCount + 100;   { 100 at runtime }
  gtouch := 0;
  if reduce(trips) <> 10201 then
    Halt(1);
  if gtouch <> 101 then
    Halt(2);
  writeln('ok');
end.
