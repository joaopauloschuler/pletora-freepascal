{ %NORUN }
{ FPC Unleashed -- cross-unit inline-asm splicing fixture (defining unit).

  Every routine below carries an inner `asm ... end` STATEMENT block.  When the
  using program is built WITHOUT -dNOINL these are `inline` and, being
  cross-unit-safe (registers/immediates/global refs/value params only), are
  spliced into the caller from this unit's ppu; with -dNOINL they are ordinary
  out-of-line routines.  Both builds must produce identical output.

  clampz() intentionally uses an AB_LOCAL asm label: it CANNOT be reconstructed
  cross-unit, so it is flagged cross-unit-unsafe and stays out of line even in
  the inlined build -- but still runs correctly. }
{$mode objfpc}
unit asmcu_lib;

interface

var
  gsrc, gdst: longint;

{$ifdef NOINL}
function addg(x: longint): longint;
function combo(x: longint): longint;
procedure copyglobals;
function clampz(x: longint): longint;
{$else}
function addg(x: longint): longint; inline;
function combo(x: longint): longint; inline;
procedure copyglobals; inline;
function clampz(x: longint): longint; inline;
{$endif}

implementation

{ global data ref (top_ref to a GLOBAL) + value param (top_local) + result }
function addg(x: longint): longint;
begin
  asm
    movl gsrc(%rip), %eax
    addl x, %eax
    movl %eax, result
  end;
end;

{ value param + global + an immediate-to-mem32 store (the `mov imm8s,mem32`
  size class that lost its operand size across the ppu round trip) }
function combo(x: longint): longint;
begin
  asm
    movl x, %eax
    addl gsrc, %eax
    movl %eax, result
    movl $42, gdst          // immediate -> mem32: size must survive
  end;
end;

{ global -> global copy, registers + two GLOBAL top_ref symbols }
procedure copyglobals;
begin
  asm
    movl gsrc(%rip), %eax
    movl %eax, gdst(%rip)
  end;
end;

{ UNSAFE cross-unit: local asm label -- kept out of line, still correct }
function clampz(x: longint): longint;
begin
  asm
    movl x, %eax
    cmpl $0, %eax
    jge .Lok
    xorl %eax, %eax
  .Lok:
    movl %eax, result
  end;
end;

end.
