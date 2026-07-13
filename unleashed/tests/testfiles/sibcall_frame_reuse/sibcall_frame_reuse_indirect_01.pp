{ %OPT=-O4 }
program sibcall_frame_reuse_indirect_01;

{ Regression for the SECOND unsound hole in the -O4 "sibling tail-call frame
  reuse" peephole (self-host blocker #5): an INDIRECT tail call.

  The peephole (TX86AsmOptimizer.PostPeepholeOptCall / DebugMsg
  "CallFrameRet2Jmp done (sibling tail-call frame reuse)") hoists the frame
  teardown above the tail call and turns the call into a jmp -- but originally
  did NOT check that the call is a DIRECT call to a symbol.  An indirect call
  (procvar / virtual method) holds its target in a register or memory operand:

      leaq  -32(%rsp),%rsp        ; frame
      ... arg-computing calls; the procvar target survives in %rbx ...
      leaq   32(%rsp),%rsp        ; HOISTED teardown: releases the frame ...
      popq   %rbx                 ; ... and POPS the register holding the target
      jmp    *%rbx                ; -> caller's stale %rbx = garbage -> crash

  The compiler itself makes virtual/procvar tail calls constantly, so this is
  why plain -O4 miscompiled the self-hosted compiler (ppc2 crashed on ANY
  input).  Fixed by gating the transform on a direct call to a symbol (indirect
  calls -- through a register or memory -- are rejected).

  Before the fix: -O4 crashes (Runtime error 216 / EAccessViolation); -O3/-O2
  are fine.  After the fix: 'ok' at every level. }

{$mode objfpc}

type
  TFn = function(a,b,c : int64) : int64;

function add3(a,b,c : int64) : int64; noinline;
begin
  add3 := a + b + c;
end;

function side(x : int64) : int64; noinline;
begin
  side := x * 2;
end;

{ local array forces a leaq-style frame teardown; the procvar target must
  survive across the arg-computing side() calls, so it is held in a
  callee-saved register (spilled from a frame slot) that the hoisted teardown
  pops -- the tail call is `call *%reg`. }
function outer(f : TFn; x : int64) : int64; noinline;
var
  loc : array[0..3] of int64;
  i : integer;
begin
  for i := 0 to 3 do
    loc[i] := x + i;
  outer := f(side(loc[0]), side(loc[1]), side(loc[2]));
end;

begin
  { loc=[10,11,12,13]; side->[20,22,24]; add3(20,22,24)=66 }
  if outer(@add3, 10) <> 66 then
    begin
      writeln('FAIL: outer=', outer(@add3, 10), ' expected 66');
      halt(1);
    end;
  writeln('ok');
end.
