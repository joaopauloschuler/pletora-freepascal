{ %OPT=-OoCONSTEVAL }
{ Loop-body fold fixture for -OoCONSTEVAL: a proven-CONST routine whose body
  is a plain counted for-loop (iterative factorial / power / running sum) is
  interpreted by the bounded evaluator and its all-constant call replaced by the
  computed literal.  This exercises the loop-evaluator paths that only became
  reachable once -OoPURE learned that a counted for-loop's lowered counter step
  (temp writes + an unchecked inc/succ on a local counter) is not a side effect.
  Folding is a no-op on the observable result, so every check must hold whether
  or not the switch is active -- this test belongs to the byte-identical suite
  baseline under both a plain run and a -OoCONSTEVAL-forced run. }
program consteval_loop_01;

{$mode objfpc}{$Q-}{$R-}

{ iterative factorial via an ascending counted for }
function ifact(n: longint): longint;
var i, r: longint;
begin
  r := 1;
  for i := 2 to n do
    r := r * i;
  ifact := r;
end;

{ integer power via a for-loop that never executes when e = 0 }
function ipow(b, e: longint): longint;
var i, r: longint;
begin
  r := 1;
  for i := 1 to e do
    r := r * b;
  ipow := r;
end;

{ descending counted for with an early break in the body }
function sumdown(n: longint): longint;
var i, s: longint;
begin
  s := 0;
  for i := n downto 1 do
    begin
      if i = 3 then break;
      s := s + i;
    end;
  sumdown := s;
end;

{ nested for-loops (multiplication table diagonal sum) }
function trisum(n: longint): longint;
var i, j, s: longint;
begin
  s := 0;
  for i := 1 to n do
    for j := 1 to i do
      s := s + j;
  trisum := s;
end;

begin
  if ifact(6) <> 720 then halt(1);
  if ifact(1) <> 1 then halt(2);       { loop body never runs }
  if ifact(0) <> 1 then halt(3);       { empty range }
  if ipow(2, 10) <> 1024 then halt(4);
  if ipow(7, 0) <> 1 then halt(5);     { e = 0: empty range }
  if sumdown(6) <> 15 then halt(6);    { 6+5+4, breaks at 3 }
  if trisum(4) <> 20 then halt(7);     { 1 + (1+2) + (1+2+3) + (1+2+3+4) }
end.
