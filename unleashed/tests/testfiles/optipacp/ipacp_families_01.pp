{ %OPT="-O2 -OoIPACP" }
{ -OoIPACP interprocedural constant propagation via function cloning: two call
  families passing different compile-time constants to a routine (deg=2 and
  deg=3) each get a specialized clone with the constant folded in, while a
  call passing a runtime value keeps the general body.  All three paths must
  compute the same results as the reference, and a side-effecting OTHER
  argument at a specialized site must still be evaluated exactly once. }
program ipacp_families_01;
{$mode objfpc}{$H+}

var calls: longint = 0;

function Bump: longint;
begin
  inc(calls);
  Bump := calls;
end;

{ deg is the specialized parameter; the loop bound folds to a constant in a
  clone.  base is passed normally (and, at one site, is a side-effecting call). }
function Poly(base, deg: longint): longint;
var i, r: longint;
begin
  r := 1;
  if deg < 0 then
    exit(-1);
  for i := 1 to deg do
    r := r * base;
  Poly := r;
end;

function refpoly(base, deg: longint): longint;
var i: longint;
begin
  refpoly := 1;
  if deg < 0 then exit;
  for i := 1 to deg do refpoly := refpoly * base;
end;

var
  b, d: longint;
begin
  { family deg=2 and deg=3, many bases -> two clones, shared across calls }
  for b := -3 to 7 do
    begin
      if Poly(b, 2) <> refpoly(b, 2) then Halt(1);
      if Poly(b, 3) <> refpoly(b, 3) then Halt(2);
    end;

  { runtime deg -> general body }
  for d := 0 to 6 do
    for b := 0 to 4 do
      if Poly(b, d) <> refpoly(b, d) then Halt(3);

  { side-effecting other argument at a specialized (deg=2) site: evaluate once }
  calls := 0;
  if Poly(Bump, 2) <> 1 then Halt(4);   { Bump returns 1, 1^2 = 1 }
  if calls <> 1 then Halt(5);           { Bump must have run exactly once }

  Halt(0);
end.
