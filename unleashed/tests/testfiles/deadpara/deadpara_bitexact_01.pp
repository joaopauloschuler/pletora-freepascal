{ %OPT=-OoDEADPARA }
{ Bit-exact runtime fixture for -OoDEADPARA (interprocedural dead-parameter
  elimination, part (a) of the gcc -fipa-sra port).  The optimization elides, at
  a resolved direct call site, the EVALUATION of a side-effect-free actual bound
  to a parameter the callee provably never reads -- it must never change the
  observable result, so every value below is identical whether or not
  -OoDEADPARA is active and this test belongs to the byte-identical suite
  baseline under both a plain run and a -OoDEADPARA-forced run.

  It exercises the safety-critical cases:
   * a helper that ignores its 2nd (by-value scalar) parameter fed an EXPENSIVE
     pure actual -- the computation may be elided but the result is unchanged;
   * a helper that ignores a parameter fed a SIDE-EFFECTING actual (a call that
     bumps a global counter) -- the side effect MUST still happen exactly once
     per call, proving evaluation order/count is preserved and only provably
     side-effect-free actuals are ever elided;
   * a helper that DOES read the parameter -- always evaluated. }
program deadpara_bitexact_01;

{$mode objfpc}{$Q-}{$R-}

var
  sidecalls: longint;

{ ignores its 2nd parameter }
function ignore2(used, dead: longint): longint; noinline;
begin
  ignore2 := used * 2 + 1;
end;

{ reads both parameters }
function useboth(a, b: longint): longint; noinline;
begin
  useboth := a + b;
end;

{ a side-effecting expression source: bumps a global counter and returns a value }
function sidefx(x: longint): longint; noinline;
begin
  inc(sidecalls);
  sidefx := x * x + 1;
end;

var
  i, acc: longint;
begin
  sidecalls := 0;
  acc := 0;

  { expensive PURE dead actual (elidable) }
  for i := 1 to 20 do
    acc := acc + ignore2(i, i*i*i + i*i + i*13);

  { SIDE-EFFECTING dead actual (must NOT be elided: sidecalls must count 20) }
  for i := 1 to 20 do
    acc := acc + ignore2(i, sidefx(i));

  { parameter genuinely read (always evaluated) }
  for i := 1 to 20 do
    acc := acc + useboth(i, i*i*i + i*i);

  writeln('acc=', acc);
  writeln('sidecalls=', sidecalls);
end.
