{ %OPT=-OoCONSTEVAL }
{ Shift-fold fixture for -OoCONSTEVAL: a proven-CONST routine that shifts by a
  (parameter) count folds when its actuals are constants, and the folded literal
  must be bit-identical to the SAME routine called at run time (mutable-global
  args). The count is masked exactly as x86-64 codegen masks it -- mod 64 for a
  64-bit result, mod 32 otherwise, so a >width shift is count-mod-width (never
  zeroed) -- and shr is a logical (zero-fill) shift even for a signed operand.
  Folding is a no-op on the observable result, so this test is byte-identical
  under a plain run and a -OoCONSTEVAL-forced run. }
program consteval_shift_01;

{$mode objfpc}{$Q-}{$R-}

function shl_l(x: longint; c: longint): longint; begin shl_l := x shl c; end;
function shr_l(x: longint; c: longint): longint; begin shr_l := x shr c; end;
function shl_q(x: int64;   c: longint): int64;   begin shl_q := x shl c; end;
function shr_q(x: int64;   c: longint): int64;   begin shr_q := x shr c; end;

var
  { mutable globals -> a genuine runtime call, same values as the folded ones }
  g1: longint = 1;  gm8: longint = -8;  gc40: longint = 40;  gc33: longint = 33;
  gc1: longint = 1; q1: int64 = 1;      gc65: longint = 65;  gc64: longint = 64;
begin
  { longint: count 40 -> 40 mod 32 = 8 }
  if shl_l(1, 40) <> shl_l(g1, gc40) then halt(1);
  { longint: count 33 -> 1 }
  if shl_l(1, 33) <> shl_l(g1, gc33) then halt(2);
  { signed shr is logical: -8 shr 1 zero-fills }
  if shr_l(-8, 1) <> shr_l(gm8, gc1) then halt(3);
  { int64: count 65 -> 65 mod 64 = 1 }
  if shl_q(1, 65) <> shl_q(q1, gc65) then halt(4);
  { int64: count 64 -> 0 -> unchanged }
  if shl_q(1, 64) <> shl_q(q1, gc64) then halt(5);
  { spot-check absolute folded values, not just folded==runtime }
  if shl_l(1, 40) <> 256 then halt(6);
  if shr_l(-8, 1) <> 2147483644 then halt(7);
  if shl_q(1, 65) <> 2 then halt(8);
  if shl_q(1, 64) <> 1 then halt(9);
end.
