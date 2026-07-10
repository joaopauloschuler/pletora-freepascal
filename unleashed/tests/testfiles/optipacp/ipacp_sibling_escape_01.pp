{ %OPT=-O4 -OoIPACP }
{ -OoIPACP used to DECLINE routines with two or more non-nested sibling counted
  for-loops or with a for-counter that escapes its loop, because turning the loop
  bounds into compile-time constants fed the -O4 loop passes shapes they
  miscompiled (the -OoREASSOC / -OoLOOPUNROLL escaping-counter bugs).  With those
  fixed the guards are relaxed.  Here a clone has two sibling loops reusing a
  counter that escapes; the specialized result must equal the unoptimised one. }
program ipacp_sibling_escape_01;
{$mode unleashed}
var g: array[0..255] of longint;
function work(n: longint): longint;
var i, s: longint;
begin
  for i := 0 to n - 1 do g[i] := i * 2;
  s := 0;
  for i := 0 to n - 1 do s := s + g[i];
  work := s * 100 + i;      { i escapes: = n-1 }
end;
begin
  if work(10) <> 9009   then Halt(1);   { s=90,  i=9  }
  if work(50) <> 245049 then Halt(2);   { s=2450,i=49 }
end.
