{ %OPT=-O4 -OoMODREF }
{ -OoMODREF per-location consumer in -OoSINK (sink_call_movable).

  -OoSINK moves a pure assignment  V := <rhs>  that precedes an if into the
  single arm that reads V (when V is dead on the fall-through).  -OoMODREF admits
  a CALL rhs when the callee WRITES NO MEMORY, is NON-TRAPPING and READS only an
  EXACT set of statics (never by-ref), and the intervening if-CONDITION does not
  write any static the call reads.  Sinking makes the read-only non-trapping call
  execute conditionally (fewer times) -- unobservable -- and reads the same
  values.

  Correctness must hold whether or not the sink fires:

    * usesink: the condition (b>0) writes nothing, so rd(a) may sink into the
      consuming arm.  Value identical sunk or not.

    * nosink: the condition calls bumpB, which writes gB -- the very static rd
      reads.  The region scan must keep rd BEFORE the condition; a wrong sink
      would read rd AFTER bumpB incremented gB and change the result (17 -> 22).

  ParamCount keeps the branch conditions opaque. Halt(nonzero)=failure. }
program sink_modref_01;
{$mode objfpc}{$H+}

var
  gB: longint;

{ writes nothing, reads only static gB, cannot trap; @tt makes -OoPURE reject }
function rd(x: longint): longint;
var
  tt: longint;
begin
  tt := gB * x;
  if @tt = nil then rd := 0 else rd := tt + 1;
end;

{ a condition that WRITES gB (and reads it) -- returns true here }
function bumpB(b: longint): boolean;
begin
  gB := gB + 1;
  bumpB := (b + gB) > 0;
end;

{ condition (b>0) writes nothing rd reads -> rd(a) sinks into the then-arm }
function usesink(a, b: longint): longint;
var
  v: longint;
begin
  v := rd(a);
  if b > 0 then
    usesink := v + 1
  else
    usesink := 100;
end;

{ condition calls bumpB (writes gB) -> rd(a) must NOT sink past it }
function nosink(a, b: longint): longint;
var
  v: longint;
begin
  v := rd(a);
  if bumpB(b) then
    nosink := v + 1
  else
    nosink := 100;
end;

var
  p: longint;
begin
  p := ParamCount;   { 0 at runtime, opaque to the optimizer }

  gB := 3;
  { rd(5)=3*5+1=16, then-arm taken -> 17 }
  if usesink(5, 1 + p) <> 17 then
    Halt(1);
  { else-arm taken -> 100 (rd sunk into the never-taken then-arm) }
  if usesink(5, -1 - p) <> 100 then
    Halt(2);

  gB := 3;
  { rd read (16) BEFORE bumpB increments gB; then-arm -> 17.  A wrong sink would
    read rd after gB became 4 -> 3*5*... -> 22 }
  if nosink(5, 1 + p) <> 17 then
    Halt(3);

  writeln('ok');
end.
