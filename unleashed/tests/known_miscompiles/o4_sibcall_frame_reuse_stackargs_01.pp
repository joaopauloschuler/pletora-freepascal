program o4_sibcall_frame_reuse_stackargs_01;
{ KNOWN -O4 MISCOMPILE (self-host blocker; the FIRST plain-`-O4` MISCOMPILE,
  distinct from the four DFA/sink false-positive blockers before it, which were
  all warning-only).  Reduced from the `-O4` self-host cycle: with self-host
  blocker #4 (the nested-proc-def DFA false positive) fixed, plain `OPT="-O4"`
  compiles the whole compiler, but the resulting stage-2 compiler (ppc2, built
  by ppc1 at -O4) is MISCOMPILED and crashes (EAccessViolation) on any input.

  Root cause: the fork's "sibling tail-call frame reuse" peephole
  (TX86AsmOptimizer.PostPeepholeOptCall / DebugMsg "CallFrameRet2Jmp done
  (sibling tail-call frame reuse)", compiler/x86/aoptx86.pas ~18743), gated
  directly on `cs_opt_level4` (NOT on the -OoSIBCALL toggle -- so disabling
  every level-4 -Oo pass does NOT disable it; only -O2/-O3 are clean).  For a
  routine that ends in a tail call and whose epilogue is a plain stack release
  (`leaq N(%rsp),%rsp` / `addq $N,%rsp`) plus optional callee-saved pops, it
  hoists a COPY of that teardown ABOVE the call and turns the call into a jmp:

      leaq  -88(%rsp),%rsp        ; allocate frame
      ... stage args, incl. the 7th/8th in the outgoing parameter area ...
      leaq   88(%rsp),%rsp        ; HOISTED teardown -- releases the frame
      jmp    inner                ; tail call

  The soundness argument only covers callee-saved register POPS versus argument
  REGISTERS; it MISSES stack-passed arguments.  When the callee takes more than
  six integer/pointer arguments (or any stack-passed argument), those arguments
  are staged in the outgoing-parameter area at the BOTTOM of the very frame the
  hoisted `leaq N(%rsp),%rsp` releases, so releasing rsp before the jmp leaves
  the callee reading them from above the (now-restored) rsp -> garbage.

  Repro: ppcx64 -O4 o4_sibcall_frame_reuse_stackargs_01.pp -> prints garbage /
         halts FAIL; ppcx64 -O3 (or -O2) -> prints 'ok'.  Present in the fork
         only (this is a fork-added peephole).  Fix must relocate/keep the
         outgoing stack arguments (or refuse the transform when the callee has
         stack-passed parameters), NOT release the frame before the jmp. }

{$mode objfpc}

{ eight int64 arguments: the 7th and 8th are passed on the stack (SysV: only
  rdi,rsi,rdx,rcx,r8,r9 are integer arg registers). }
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
