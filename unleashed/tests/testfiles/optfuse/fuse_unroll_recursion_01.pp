{ %OPT=-O4 -OoIPACP }
{ -OoLOOPFUSE greedily folds a run of adjacent same-space counted for-loops into
  one survivor loop, re-first-passing the survivor after each fold.  do_firstpass
  is a var-param: for a CONSTANT-TRIP survivor, tfornode.pass_typecheck runs the
  stock loop unroller, which can fully unroll it (getridoffor) into a plain block
  with no for-node left.  The greedy loop then reinterpreted that block as a
  tfornode on its next iteration and walked it as a for-node -> compiler stack
  overflow / internalerror.  (Reached here through -OoIPACP cloning of work() at
  constant trips 3/4/5, producing four sibling constant-trip loops that fuse then
  unroll.)  Fixed by stopping the greedy fold once the survivor is no longer a
  counted for-loop.  The program must simply compile and run correctly. }
program fuse_unroll_recursion_01;
{$mode objfpc}{$H+}
var a,b,c,d: array of longint;

function work(n: longint): longint;
var i: longint;
begin
  SetLength(a,n); SetLength(b,n); SetLength(c,n); SetLength(d,n);
  for i:=0 to n-1 do b[i]:=i;
  for i:=0 to n-1 do a[i]:=b[i];
  for i:=0 to n-1 do c[i]:=b[i];
  for i:=0 to n-1 do d[i]:=b[i];
  work := a[n-1] + c[n-1] + d[n-1];
end;

begin
  if work(3) <> 6 then Halt(1);   { a[2]=c[2]=d[2]=2 -> 6 }
  if work(4) <> 9 then Halt(2);   { each =3 -> 9 }
  if work(5) <> 12 then Halt(3);  { each =4 -> 12 }
end.
