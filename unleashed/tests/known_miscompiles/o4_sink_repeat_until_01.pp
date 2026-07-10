program o4_sink_repeat_until_01;
{ KNOWN -O4 MISCOMPILE (reduced from compiler/rgobj.pas register-spill loop).

  Pattern: a `repeat` loop whose controlling boolean is UNCONDITIONALLY
  re-initialized to true at the top of the body and then only sometimes
  overwritten inside an `if`:

      repeat
        endspill := true;             { re-init every iteration }
        if <cond> then
          begin ...
            endspill := <expr>;       { conditional override }
          end;
      until endspill;

  At -O4 the store-sink pass (-OoSINK), interacting with the loop pipeline,
  sinks the unconditional `endspill:=true` store so the `until endspill` test
  re-reads a stale value -> the loop never terminates (INFINITE LOOP).  The same
  restructuring also makes the dataflow uninitialized-variable checker emit a
  spurious "Local variable endspill does not seem to be initialized" warning
  (gated by -OoTAILDUP), which -- treated as an error in the compiler's own
  build -- aborts the -O4 self-host at compiler/rgobj.pas line 688.

  Verdicts (compile with:  ppcx64 -Fu<rtl> <opt> o4_sink_repeat_until_01.pp):
     -O2                : exit 2  (correct)      no warning
     -O3                : exit 2  (correct)      no warning
     -O4 -OoNOSINK      : exit 2  (correct)      no warning
     -O4                : INFINITE LOOP          spurious "not initialized" warn
     -O4 -OoNOTAILDUP   : INFINITE LOOP          no warning (miscompile persists)

  Deliberately NOT under testfiles/ so the shell suite baseline stays clean;
  run it directly.  Wrap the run in `ulimit -v` + `timeout` -- at plain -O4 it
  does not terminate. }
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
  { Correct result is 2.  A -O4 build never reaches here (it spins in run). }
  Halt(run);
end.
