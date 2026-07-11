program o4_unrolljam_varying_inner_bound_01;
{ KNOWN -O4 MISCOMPILE (self-host blocker #6; the SECOND plain-`-O4` codegen
  miscompile, distinct from and independent of blocker #5 -- the sibling
  tail-call frame-reuse peephole).  With blocker #5 fixed, plain OPT="-O4"
  compiles the whole compiler and the stage-2 compiler ppc2 now runs on simple
  inputs, but it still CRASHES (EAccessViolation, memory corruption) when
  compiling more complex sources such as the RTL's system.pp, aborting the
  self-host cycle at CYCLELEVEL=3.

  CONFIRMED DISTINCT ROOT CAUSE: the crash reproduces with the -O4 sibling
  tail-call peephole FULLY DISABLED, so it is NOT blocker #5.  gdb on a
  line-info ppc2 traces the crash to a corrupt virtual dispatch inside
  TStoredSymtable-based lookup (symtable.pas search_macro), i.e. heap/global
  corruption from an out-of-bounds write elsewhere.  Single-pass optimizer-pass
  bisection (-OoNO* switches while building ppc2) pins it to exactly ONE pass:
  -OoUNROLLJAM (cs_opt_unrolljam, the unroll-and-jam pass, gated in -O4).  The
  only routine unroll-and-jammed in the whole compiler build is
  TMessage.ResetStates (compiler/cmsgs.pas:482, "outer factor 4"), whose inner
  loop trip count `msgidxmax[i]` DEPENDS ON THE OUTER LOOP COUNTER i:

      for i:=1 to msgparts do
        for j:=0 to msgidxmax[i]-1 do      { inner bound varies with i }
          msgstates[i][j]:=...;             { in-place read-modify-write }

  Unroll-and-jam unrolls the outer loop by K=4 and JAMS the K inner loops into
  one -- which is only sound when the K inner loops have the SAME trip count.
  Here rows i, i+1, i+2, i+3 have DIFFERENT lengths, so the jammed inner loop
  drives all K rows with one (wrong) bound -> reads/writes out of each row's
  valid range -> wrong values and out-of-bounds stores that corrupt adjacent
  memory.  The pass must refuse to jam (or must peel/guard per unrolled copy)
  when the inner loop's count is not invariant across the unrolled outer
  iterations (i.e. depends on the outer counter).

  This reduced program mirrors ResetStates: a per-row length array rowlen[i]=i
  drives the inner bound, and the ResetLike nest read-modify-writes only the
  valid prefix of each row.  ppcx64 -O4 -> FAIL (wrong values / row overrun);
  ppcx64 -O4 -OoNOUNROLLJAM and -O3/-O2 -> ok. }

{$mode objfpc}

const P = 8;
type
  TRows = array[1..P] of longint;
  TGrid = array[1..P,0..15] of int64;
var
  rowlen : TRows;
  a      : TGrid;

{ the ResetStates-shaped nest: one two-level loop nest, inner bound rowlen[i]
  depends on the outer counter i, in-place read-modify-write of a[i][j]. }
procedure ResetLike;
var i,j : longint; v : int64;
begin
  for i:=1 to P do
    for j:=0 to rowlen[i]-1 do
      begin
        v:=a[i,j];
        v:=v+1;
        a[i,j]:=v;
      end;
end;

var i,j : longint;
begin
  for i:=1 to P do rowlen[i]:=i;                 { row i has i valid elements }
  for i:=1 to P do for j:=0 to 15 do a[i,j]:=100; { sentinel for the tail }
  for i:=1 to P do for j:=0 to rowlen[i]-1 do a[i,j]:=i*10+j;

  ResetLike;

  for i:=1 to P do
    for j:=0 to 15 do
      if j<=rowlen[i]-1 then
        begin
          if a[i,j]<>i*10+j+1 then
            begin writeln('FAIL valid a[',i,',',j,']=',a[i,j],' expected ',i*10+j+1); halt(1); end;
        end
      else
        begin
          if a[i,j]<>100 then
            begin writeln('FAIL sentinel a[',i,',',j,']=',a[i,j],' (row overrun)'); halt(1); end;
        end;
  writeln('ok');
end.
