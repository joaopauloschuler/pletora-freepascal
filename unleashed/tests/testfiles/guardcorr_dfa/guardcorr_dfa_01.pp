{ %OPT="-O4 -Sew" }
program guardcorr_dfa_01;

{ Regression for the -O4 (DFA) "does not seem to be initialized" false positive
  on a scalar local assigned under `if COND then ...` and later read under a
  second `if COND then ...` guarded by the SAME boolean, with COND unchanged in
  between (compiler/optdfa.pas CollectCorrelatedGuardSyms; self-host blocker on
  compiler/pstatmnt.pas ~5352, local `remaining_sym`).

  The DFA cannot correlate the two guards, so it assumes the read may be reached
  without the assignment.  It is a false positive: whenever the second guard's
  body runs, COND was true, so the first guard's body ran and defined the
  variable.  Warning-only, and present in upstream FPC 3.2.2 too; but the fork's
  self-host build uses -Sew (warnings-as-errors), so the spurious note is fatal.

  Compiles clean at -O4 -Sew with the fix; the %OPT above makes the note fatal,
  and the program below verifies codegen is correct. }

{$mode objfpc}

function compute(enabled : boolean; base : int64) : int64;
var
  remaining : int64;
  acc : int64;
  i : integer;
begin
  acc := 0;
  if enabled then
    remaining := base;
  for i := 1 to 3 do
    acc := acc + i;
  if enabled then
    begin
      acc := acc + remaining;       { read under the SAME guard that set it }
      remaining := remaining - 1;
      acc := acc + remaining;
    end;
  compute := acc;
end;

{ second shape: a plain local (not a parameter) as the guard, several reads }
function pick(flag : boolean; n : int64) : int64;
var
  sel : int64;
  on : boolean;
begin
  on := flag;
  if on then
    sel := n * 2;
  if on then
    pick := sel + 1
  else
    pick := 0;
end;

begin
  if compute(true, 100) <> 205 then
    begin writeln('FAIL compute true'); halt(1); end;
  if compute(false, 100) <> 6 then
    begin writeln('FAIL compute false'); halt(1); end;
  if pick(true, 10) <> 21 then
    begin writeln('FAIL pick true'); halt(1); end;
  if pick(false, 10) <> 0 then
    begin writeln('FAIL pick false'); halt(1); end;
  writeln('ok');
end.
