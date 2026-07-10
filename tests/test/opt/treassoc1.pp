{ %OPT=-O3 -OoREASSOC -OoFASTMATH }

{ IE 200309289: the REASSOC reduction pass clones the accumulated expression
  for its partial sums and force-retypechecks the clones; a load of a variable
  captured from the enclosing frame still carried the original's parentfp node
  in left, which the re-typecheck refuses to overwrite. The reduction must
  live in a nested procedure and read enclosing-frame variables to trigger. }

program treassoc1;
{$mode objfpc}

procedure Outer;
var
  buf: array[0..255] of single;
  n: integer;
  total: single;

  procedure Nested;
  var
    k: integer;
    s: single;
  begin
    s := 0;
    for k := 0 to n - 1 do
      s := s + buf[k];
    total := total + s;
  end;

var
  i: integer;
begin
  n := 200;
  total := 0;
  for i := 0 to 255 do
    buf[i] := i * 0.5;
  Nested;
  { sum of i*0.5 for i=0..199 = 9950; exact in single precision regardless
    of the reassociated summation order }
  if total <> 9950.0 then
    halt(1);
end;

begin
  Outer;
  writeln('ok');
end.
