{ %OPT=-O4 }
program sibcall_frame_reuse_stackargs_01;

{ Regression for the -O4 "sibling tail-call frame reuse" peephole miscompile
  (self-host blocker #5 -- the FIRST plain -O4 codegen miscompile).

  The fork peephole TX86AsmOptimizer.PostPeepholeOptCall / DebugMsg
  "CallFrameRet2Jmp done (sibling tail-call frame reuse)" (gated directly on
  cs_opt_level4, NOT on -OoSIBCALL) turns a framed routine's tail call into a
  jmp by hoisting the frame teardown (leaq N(%rsp),%rsp / addq $N,%rsp plus
  optional callee-saved pops) ABOVE the call.  Its soundness argument only
  covered callee-saved register POPS vs argument REGISTERS and MISSED
  stack-passed arguments: when the callee takes more than six integer/pointer
  args (SysV: only rdi,rsi,rdx,rcx,r8,r9 are integer arg registers), the 7th+
  args are staged in the outgoing-parameter area at the BOTTOM of the very
  frame the hoisted teardown releases, so releasing rsp before the jmp leaves
  the callee reading them from above the restored rsp -> garbage.

  Fixed by gating the transform on current_procinfo.maxpushedparasize=0 (no
  outgoing stack args to ANY callee, proven from the caller side), plus a
  plain-caller-convention and non-ms_abi gate.

  Before the fix: -O4 prints garbage and halts FAIL; -O3/-O2 print 'ok'.
  After the fix: 'ok' at every level. }

{$mode objfpc}

{ eight int64 arguments: the 7th and 8th are passed on the stack. }
function inner(a,b,c,d,e,f,g,h : int64) : int64; noinline;
begin
  inner := a + b + c + d + e + f + g + h;
end;

{ a routine with its own frame (the local array forces a stack frame with a
  plain leaq/addq teardown) that ends in a tail call taking stack arguments. }
function outer(x : int64) : int64; noinline;
var
  loc : array[0..7] of int64;
  i : integer;
begin
  for i := 0 to 7 do
    loc[i] := x + i;
  outer := inner(loc[0],loc[1],loc[2],loc[3],loc[4],loc[5],loc[6],loc[7]);
end;

begin
  { x=10 -> 10+11+12+13+14+15+16+17 = 108 }
  if outer(10) <> 108 then
    begin
      writeln('FAIL: outer(10)=', outer(10), ' expected 108');
      halt(1);
    end;
  writeln('ok');
end.
