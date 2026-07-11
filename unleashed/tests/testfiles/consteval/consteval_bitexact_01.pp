{ %OPT=-OoCONSTEVAL }
{ Bit-exact runtime fixture for -OoCONSTEVAL: a call to a proven-CONST routine
  with all-constant arguments is replaced by the computed literal.  Every check
  below must hold whether or not the switch is active (folding is a no-op on the
  observable result), so this test belongs to the byte-identical suite baseline
  under both a plain run and a -OoCONSTEVAL-forced run.  It exercises two's-
  complement wraparound, signed/unsigned comparison, bitwise ops, a within-cap
  recursive factorial, char/ord and a case statement. }
program consteval_bitexact_01;

{$mode objfpc}{$Q-}{$R-}

function dbl(x: longint): longint;
begin
  result := x * 2 + 1;
end;

function fact(n: longint): longint;
begin
  if n <= 1 then result := 1 else result := n * fact(n - 1);
end;

function wrapmul(a, b: longint): longint;
begin
  result := a * b;   { deliberately overflows int32; must wrap identically }
end;

function classify(a: longint; b: cardinal): longint;
begin
  if a < 0 then result := -a
  else if b > 3000000000 then result := 100
  else if a <> longint(b) then result := a - longint(b)
  else result := 0;
end;

function bits(a, b: byte): byte;
begin
  result := (a and b) or (a xor b);
end;

function chword(c: char): longint;
begin
  result := ord(c) + 1;
end;

function grade(n: longint): longint;
begin
  case n of
    0..2: result := 10;
    5:    result := 50;
    7, 9: result := 70;
  else
    result := -1;
  end;
end;

begin
  if dbl(20) <> 41 then halt(1);
  if fact(6) <> 720 then halt(2);
  if wrapmul(100000, 100000) <> 1410065408 then halt(3);
  if classify(-5, 10) <> 5 then halt(4);
  if classify(7, 4000000000) <> 100 then halt(5);
  if classify(50, 20) <> 30 then halt(6);
  if bits(200, 120) <> 248 then halt(7);
  if chword('A') <> 66 then halt(8);
  if grade(1) <> 10 then halt(9);
  if grade(9) <> 70 then halt(10);
  if grade(100) <> -1 then halt(11);
end.
