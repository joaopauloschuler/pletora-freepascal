{ %OPT="-Cg -O2" }
{$mode objfpc}
{ Regression: interaction of -OoCONSTS with -OoTAILREC (both inside -O2 here).
  Tail-recursion elimination rewrites the trailing self-call of walk() into a
  goto-loop back to the top of the body. do_consttovar's register temps are
  initialised in entry code BEFORE that label; without the trailing
  ttempdeletenode reg-sync the allocator sees no use after the last textual
  read and reuses the register for the second promoted global on the path
  after the recursive call -- one trip around the tailrec back-edge later the
  first global is addressed through the wrong base register. This mirrors
  emitdispatch/gencaseclusters in the compiler's own ncgset.pas, which made a
  compiler built with OPT="-O2" crash while compiling any casecluster case
  statement. Whether the clobber actually strikes depends on register
  pressure, so this is a smoke test for the CONSTS x TAILREC combination; the
  deterministic guard for the underlying bug is consttovar_loop_01.pp. }
program consttovar_tailrec_01;

var
  acc: array[0..3] of int64;
  steps: int64;

procedure walk(lo, hi: longint);
var
  mid: longint;
begin
  if lo = hi then
    begin
      { several references to each global => weight high enough for
        do_consttovar to promote their addresses even with calls present }
      acc[lo and 3] := acc[lo and 3] + lo;
      acc[(lo + 1) and 3] := acc[(lo + 1) and 3] + 1;
      steps := steps + 1;
      exit;
    end;
  mid := (lo + hi) div 2 + 1;
  walk(mid, hi);        { genuine recursion }
  walk(lo, mid - 1);    { tail call -> lowered to a goto loop by -OoTAILREC }
end;

var
  i: longint;
  total: int64;
begin
  walk(0, 1023);
  if steps <> 1024 then
    begin
      writeln('FAIL steps=', steps);
      halt(1);
    end;
  total := 0;
  for i := 0 to 3 do
    total := total + acc[i];
  { sum 0..1023 plus 1024 increments of 1 }
  if total <> (1023 * 1024) div 2 + 1024 then
    begin
      writeln('FAIL total=', total);
      halt(2);
    end;
  writeln('OK');
end.
