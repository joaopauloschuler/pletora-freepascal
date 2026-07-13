{ %OPT="-O4 -Sew" }
program nestedprocdef_dfa_01;

{ Regression for the -O4 (DFA) "does not seem to be initialized" false positive
  on a local of an enclosing routine that is assigned ONLY inside a nested
  procedure/function which the enclosing routine calls BEFORE reading the local
  (compiler/optdfa.pas CollectNestedProcDefSyms, wired in compiler/psub.pas;
  self-host blocker on compiler/x86/aoptx86.pas ~19282 anchors/acount and ~19555
  anchor, in TX86AsmOptimizer.DoCrossJump via nested CollectAnchors/FindAnchor).

  The -O3/-O4 uninitialized-variable DFA does not model a call to a nested
  routine as a (potential) definition of the captured parent local, so it
  assumes the later read may be reached without the assignment.  It is a false
  positive: the nested routine always runs before the read and always defines
  the local.  Clean at -O2 (the node DFA only runs at -O3+), warns at -O3/-O4,
  and present in upstream FPC 3.2.2 too; but the fork's self-host build uses
  -Sew (warnings-as-errors), so the spurious note is fatal.

  Compiles clean at -O4 -Sew with the fix; the %OPT above makes the note fatal,
  and the program below verifies codegen is correct. }

{$mode objfpc}

type
  tobj = class end;

{ shape 1: managed/class and scalar locals defined only in a nested procedure }
function build(n : integer) : integer;
var
  anchor : tobj;
  cnt : integer;

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
  if not assigned(anchor) then
    exit(0);
  build := cnt;
  anchor.free;
end;

{ shape 2: nested-of-nested writes a grandparent local, called through the
  intermediate nested routine before the read }
function build2(n : integer) : integer;
var
  total : integer;

  procedure outer;

    procedure inner;
    begin
      total := n * 2;
    end;

  begin
    inner;
  end;

begin
  outer;
  build2 := total;
end;

begin
  if build(3) <> 3 then
    begin writeln('FAIL build n>1'); halt(1); end;
  if build(1) <> 0 then
    begin writeln('FAIL build n<=1'); halt(1); end;
  if build2(5) <> 10 then
    begin writeln('FAIL build2'); halt(1); end;
  writeln('ok');
end.
