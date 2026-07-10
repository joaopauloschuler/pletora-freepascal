{ %OPT="-O2 -OoIPACP" }
{ -OoIPACP soundness corners: (1) recursion -- specializing a constant argument
  at a recursive call is sound because the clone calls the ORIGINAL routine
  recursively, never a clone of a clone; (2) size budget -- a routine whose body
  exceeds the node-count budget is left un-cloned and still computes correctly.
  Both verified bit-exact against references. }
program ipacp_recursion_budget_01;
{$mode objfpc}{$H+}

{ recursive: `depth` is specialized at the leaf call; the clone recurses into
  the general Fac. }
function Fac(n, depth: longint): longint;
begin
  if n <= 1 then
    exit(1);
  Fac := n * Fac(n - 1, depth);
end;

function refFac(n: longint): longint;
begin
  if n <= 1 then exit(1);
  refFac := n * refFac(n - 1);
end;

{ intentionally large body (well over the node budget) so it is NOT cloned;
  the constant argument sel still must yield correct results via the general
  body. }
function Big(x, sel: longint): longint;
var r: longint;
begin
  r := x;
  r := r + 1; r := r * 2; r := r - 3; r := r + 4; r := r * 5;
  r := r - 6; r := r + 7; r := r * 8; r := r - 9; r := r + 10;
  r := r xor 11; r := r + 12; r := r * 13; r := r - 14; r := r + 15;
  r := r + 16; r := r * 17; r := r - 18; r := r + 19; r := r * 20;
  r := r - 21; r := r + 22; r := r * 23; r := r - 24; r := r + 25;
  r := r xor 26; r := r + 27; r := r * 28; r := r - 29; r := r + 30;
  r := r + 31; r := r * 32; r := r - 33; r := r + 34; r := r * 35;
  r := r - 36; r := r + 37; r := r * 38; r := r - 39; r := r + 40;
  if sel = 0 then r := r + 100 else r := r - 100;
  Big := r;
end;

function refBig(x, sel: longint): longint;
var r: longint;
begin
  r := x;
  r := r + 1; r := r * 2; r := r - 3; r := r + 4; r := r * 5;
  r := r - 6; r := r + 7; r := r * 8; r := r - 9; r := r + 10;
  r := r xor 11; r := r + 12; r := r * 13; r := r - 14; r := r + 15;
  r := r + 16; r := r * 17; r := r - 18; r := r + 19; r := r * 20;
  r := r - 21; r := r + 22; r := r * 23; r := r - 24; r := r + 25;
  r := r xor 26; r := r + 27; r := r * 28; r := r - 29; r := r + 30;
  r := r + 31; r := r * 32; r := r - 33; r := r + 34; r := r * 35;
  r := r - 36; r := r + 37; r := r * 38; r := r - 39; r := r + 40;
  if sel = 0 then r := r + 100 else r := r - 100;
  refBig := r;
end;

var n, x: longint;
begin
  for n := 1 to 10 do
    if Fac(n, 3) <> refFac(n) then Halt(1);

  for x := -20 to 20 do
    begin
      if Big(x, 0) <> refBig(x, 0) then Halt(2);
      if Big(x, 1) <> refBig(x, 1) then Halt(3);
    end;

  Halt(0);
end.
