{ %OPT=-OoCONSTEVAL }
{ Bit-exact float fixture for -OoCONSTEVAL: a proven-CONST routine whose
  params/result/locals are single/double is interpreted with IEEE-exact
  per-step rounding (each intermediate rounded to the node's own precision, so
  a single op rounds to single per step) and its all-constant call replaced by
  the computed literal.  Each check compares the FOLDED literal against the SAME
  routine called with mutable-global arguments (identical values, but a runtime
  call the folder must leave alone), asserting the raw IEEE bit pattern is
  identical -- proving the fold is bit-for-bit what codegen produces.  Folding
  is a no-op on the observable result, so this test belongs to the byte-
  identical suite baseline under both a plain run and a -OoCONSTEVAL-forced run. }
program consteval_float_01;

{$mode objfpc}{$Q-}{$R-}

{ single chain: mul/add/sub plus an auto-sqr (t*t), all rounded to single }
function schain(a, b: single): single;
var t: single;
begin
  t := a * b + a - b;
  t := t * t - a;
  schain := t;
end;

{ double loop accumulation with int->double conversion }
function dloop(a, b: double): double;
var i: longint; s: double;
begin
  s := 0.0;
  for i := 1 to 7 do
    s := s + a * i - b;
  dloop := s;
end;

{ mixed int + double arithmetic and |x| }
function dmix(n: longint; k: double): double;
begin
  dmix := abs(n * 1.5 - k);
end;

var
  { mutable globals: the compiler cannot assume these keep their initial value,
    so a call taking them is a genuine runtime call the folder must not fold }
  ga: single = 1.1; gb: single = 2.2;
  gda: double = 3.3; gdb: double = 0.7;
  gn: longint = 3; gk: double = 0.25;
  fs, us: single;
  fd, ud: double;
begin
  fs := schain(1.1, 2.2);          { folded literal }
  us := schain(ga, gb);            { runtime call, same values }
  if PLongWord(@fs)^ <> PLongWord(@us)^ then halt(1);

  fd := dloop(3.3, 0.7);           { folded literal }
  ud := dloop(gda, gdb);           { runtime call }
  if PQWord(@fd)^ <> PQWord(@ud)^ then halt(2);

  fd := dmix(3, 0.25);             { folded literal }
  ud := dmix(gn, gk);              { runtime call }
  if PQWord(@fd)^ <> PQWord(@ud)^ then halt(3);
end.
