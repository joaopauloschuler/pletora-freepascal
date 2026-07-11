{ %OPT=-O4 }
{ Unroll-and-jam soundness with an OUTER-DEPENDENT inner bound (-O4).  This is
  the reduced form of the self-host blocker #6 miscompile: in
  TMessage.ResetStates the inner loop trip count is msgidxmax[i], which depends
  on the outer counter i.  Unroll-and-jam unrolls the outer loop by K=4 and
  jams the K inner-loop bodies into ONE inner loop driven by a SINGLE inner
  bound -- sound only when that bound is invariant across the K consecutive
  outer iterations.  Here rows i..i+3 have DIFFERENT lengths (rowlen[i]=i), so
  jamming them under one bound reads/writes out of each row's valid range ->
  wrong values and out-of-bounds stores that corrupt adjacent memory.  The pass
  must DECLINE this nest (inner bound is not outer-invariant); with the bug it
  wrote wrong values / overran rows.  A sentinel tail past each row's valid
  prefix catches the overrun; correct values catch the wrong-bound reads.
  Passes at -O4, -O4 -OoNOUNROLLJAM, -O3 and -O2. }
program unrolljam_varying_inner_bound_01;
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
          if a[i,j]<>i*10+j+1 then Halt(1);
        end
      else
        begin
          if a[i,j]<>100 then Halt(2);       { row overrun }
        end;
  Halt(0);
end.
