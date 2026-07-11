{ %OPT="-O2 -OoICF -gh" }
{ Regression for IE 200404124: -OoICF's zero-byte symbol-alias fold relocates a
  duplicate routine's entry symbol out of its own per-function .text.n_ section
  into the survivor's section. With debug info on (-gh here) the duplicate's
  per-proc DWARF address range / .debug_aranges entry uses low_pc = its symbol
  and length = <its-end-label> - <its-symbol>; after the cross-section
  relocation those operands straddle two sections and the internal assembler
  raised IE 200404124 (fantastica/fpc-torture seeds 3 & 11, via an -OoIPACP
  clone whose debug range is emitted before ICF runs, then alias-folded). The
  fold must fall back to a jmp thunk (which keeps the routine, its end-label and
  section header together) whenever per-proc debug ranges are generated.
  Foo and Bar are byte-identical and never address-taken, so ICF treats Bar as
  an alias candidate; under -gh this must now compile clean and run correct.
  Assertion is pure runtime correctness; the alias->thunk shape flip under -gh
  is asserted by unleashed/tests/icf_debug_check.sh. }
program opticf_debug_01;
{$mode objfpc}

function Foo(a,b,c,d: longint): longint; noinline;
begin
  result:=a*b+c-d; result:=result*a; result:=result xor b;
  result:=result+c*d; result:=result-a*c; result:=result or d;
  result:=result*3+7; result:=result and $7f; result:=result shl 2;
end;

function Bar(a,b,c,d: longint): longint; noinline;
begin
  result:=a*b+c-d; result:=result*a; result:=result xor b;
  result:=result+c*d; result:=result-a*c; result:=result or d;
  result:=result*3+7; result:=result and $7f; result:=result shl 2;
end;

var
  f, b, g: longint;
begin
  f := Foo(3,5,7,9);
  b := Bar(3,5,7,9);
  g := Foo(11,13,17,19) + Bar(19,17,13,11);
  if f <> b then begin writeln('FAIL: Foo<>Bar'); halt(1); end;
  if f <> 440 then begin writeln('FAIL: Foo value ', f); halt(1); end;
  if g <> (Foo(11,13,17,19) + Bar(19,17,13,11)) then begin writeln('FAIL: g'); halt(1); end;
  writeln('ok ', f, ' ', g);
end.
