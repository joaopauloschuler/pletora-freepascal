{ FPC Unleashed -- cross-unit inline-asm splicing fixture (using program).

  Exercises the asmcu_lib routines from ANOTHER unit.  Built inlined (default)
  and out-of-line (-dNOINL), the emitted output must be byte-identical. }
{$mode objfpc}
program asmcu_main;

uses
  asmcu_lib;

var
  a, b, c, d, e: longint;
begin
  gsrc := 100; gdst := 0;
  a := addg(5);            { 100 + 5   = 105 }
  b := combo(9);           { 9 + 100   = 109 ; gdst := 42 }
  c := gdst;               { 42 }
  gsrc := 77;
  copyglobals;             { gdst := gsrc = 77 }
  d := gdst;               { 77 }
  e := clampz(-4) + clampz(8) * 1000; { 0 + 8000 = 8000 }
  writeln(a, ' ', b, ' ', c, ' ', d, ' ', e);
end.
