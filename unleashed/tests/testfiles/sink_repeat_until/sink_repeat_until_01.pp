{ %OPT=-O4 }
program sink_repeat_until_01;

{ Regression for the -OoSINK repeat/until miscompile (self-host blocker).

  Pattern reduced from compiler/rgobj.pas's register-spill loop: a repeat
  loop whose controlling boolean is UNCONDITIONALLY re-initialized to true at
  the top of the body and only sometimes overwritten inside an if:

      repeat endspill := true; if cond then endspill := e; until endspill;

  At -O4 the store-sink pass used to move the unconditional endspill:=true
  store into the single if-arm that also writes endspill, so on the path
  where the if is not taken the `until endspill` test re-read a stale value
  from the previous iteration -> the loop never terminated (INFINITE LOOP),
  plus a spurious "does not seem to be initialized" warning.  Correct at -O2,
  -O3 and -O4 -OoNOSINK; must now be correct at plain -O4 as well.

  Fixed by making the sink pass treat a while/repeat loop node reached as the
  fall-through successor (the last body statement's successor is the loop
  node itself) as a use of V when the loop's controlling condition reads V. }

{$mode objfpc}

function run: longint;
var
  endspill: boolean;
  cnt, iters: longint;
begin
  cnt := 0;
  iters := 0;
  repeat
    inc(iters);
    endspill := true;              { unconditional re-init }
    if iters < 2 then              { true on iter 1 only }
      begin
        inc(cnt);
        endspill := iters >= 2;    { false on iter 1 -> one more iteration }
      end;
  until endspill;
  run := iters;                    { correct fixed point: 2 iterations }
end;

begin
  { correct result is 2; a miscompiled -O4 build spins forever in run }
  if run <> 2 then
    halt(1);
  halt(0);
end.
