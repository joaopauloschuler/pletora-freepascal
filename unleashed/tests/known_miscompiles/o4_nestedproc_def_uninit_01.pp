program o4_nestedproc_def_uninit_01;
{ KNOWN -O3/-O4 DFA FALSE POSITIVE (self-host blocker; reduced from
  compiler/x86/aoptx86.pas ~19282 `anchors`/`acount` in TX86AsmOptimizer.
  DoCrossJump, and ~19555 `anchor` in the sink-cross-jump variant).

  Pattern: a local of the enclosing routine is assigned ONLY inside a nested
  procedure/function, which the enclosing routine calls BEFORE reading the
  local.  At -O3/-O4 the dataflow uninitialized-variable checker does not model
  the nested-procedure call as a definition of the captured parent local, so it
  assumes the later read may be reached without the assignment and emits

      Local variable "anchor" does not seem to be initialized

  It is WARNING-ONLY: the nested procedure always runs before the read and
  always assigns the local, so codegen is correct (this program prints 3).  But
  the fork's self-host bootstrap builds the compiler with -Sew
  (warnings-as-errors), so the spurious note is fatal and aborts the -O4 cycle
  while compiling aoptx86.pas (the SECOND -O4 self-host blocker after the
  correlated if-guard case, o4_correlated_guard_uninit_01.pp, was fixed).

  DISTINCT root cause from the loop-fill (optdfa.pas CollectLoopFillCoveredSyms)
  and the correlated if-guard (CollectCorrelatedGuardSyms) false positives: this
  one is a scalar/managed local DEFINED THROUGH A NESTED-PROCEDURE CALL.  Clean
  at -O2, warns at -O3 and -O4; present in upstream FPC 3.2.2 too (compile with
  `ppcx64 -O3`).

  Repro:  ppcx64 -O4 o4_nestedproc_def_uninit_01.pp   -> the note fires
          (add -Sew to see it abort as an error, as the bootstrap does).
          ppcx64 -O2 o4_nestedproc_def_uninit_01.pp   -> clean (below the gate). }
{$mode objfpc}

type
  tobj = class end;

function build(n : integer) : integer;
var
  anchor : tobj;
  cnt : integer;

  { assigns BOTH captured parent locals on every path }
  procedure findanchor;
  begin
    anchor := nil;
    cnt := 0;
    if n > 1 then
      begin
        anchor := tobj.create;
        cnt := n;
      end;
  end;

begin
  findanchor;
  if not assigned(anchor) then      { read of a nested-proc-defined local }
    exit(0);
  build := cnt;                     { read of a nested-proc-defined local }
  anchor.free;
end;

begin
  if build(3) <> 3 then
    begin writeln('FAIL n>1'); halt(1); end;
  if build(1) <> 0 then
    begin writeln('FAIL n<=1'); halt(1); end;
  writeln('ok');
end.
