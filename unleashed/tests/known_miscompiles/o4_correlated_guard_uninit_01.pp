program o4_correlated_guard_uninit_01;
{ KNOWN -O3/-O4 DFA FALSE POSITIVE (self-host blocker; reduced from
  compiler/pstatmnt.pas ~5352, local var `remaining_sym` in the multi-lock
  timed-wait lowering).

  Pattern: a local is assigned inside `if cond then ...` and later read inside
  another `if cond then ...` guarded by the SAME boolean.  The dataflow
  uninitialized-variable checker cannot correlate the two guards, so it assumes
  the read may be reached without the assignment and emits

      Local variable "remaining" does not seem to be initialized

  It is WARNING-ONLY: when cond is false the variable is never read, and when it
  is true the assignment always dominates the read, so codegen is correct (this
  program prints 205 then 6).  But the fork's self-host bootstrap builds the
  compiler with -Sew (warnings-as-errors), so the spurious note is fatal and
  aborts the -O4 cycle at pstatmnt.pas.

  This is DISTINCT from the loop-fill false positive fixed on branch a3
  (optdfa.pas CollectLoopFillCoveredSyms): that one is an array element-filled
  in one for-loop and read in another; this one is a scalar under correlated
  if-guards.  Present in upstream FPC 3.2.2 too (compile with `ppcx64 -O3`).

  Repro:  ppcx64 -O4 o4_correlated_guard_uninit_01.pp   -> the note fires
          (add -Sew to see it abort as an error, as the bootstrap does). }
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

begin
  if compute(true, 100) <> 205 then
    begin writeln('FAIL true'); halt(1); end;
  if compute(false, 100) <> 6 then
    begin writeln('FAIL false'); halt(1); end;
  writeln('ok');
end.
