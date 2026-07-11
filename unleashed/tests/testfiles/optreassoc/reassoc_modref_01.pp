{ %OPT="-O4 -OoMODREF -OoREASSOC" }
{ -OoMODREF generalisation of the -OoPURE loop-pass fence relaxation for
  -OoREASSOC.  A reduction addend  acc := acc + f(a[i])  whose f is proven by
  -OoMODREF to write NO memory and to be non-trapping is side-effect free and
  reorderable, so the pass may duplicate it with a shifted counter into K partial
  accumulators -- exactly as for a proven-PURE call (the reduction body's ONLY
  store is the non-address-taken local accumulator, which no callee can name, so
  regrouping re-reads identical values).  -OoMODREF reaches routines -OoPURE
  leaves unproven: `viaaddr` takes the address of a local, which the purity
  analysis rejects outright ("takes the address of something"), yet it writes no
  external memory and cannot trap.  (Calls with open-array / managed / hidden
  actuals are ALSO admissible now -- reassoc's addend duplicator preserves the
  already-firstpassed call's expanded argument list on each copy; that
  open-array case is exercised by the sibling reassoc_modref_02.pp.)

  Correctness must hold regardless of whether the split fires: an integer sum is
  exact under any grouping.  The reference kernel takes the address of its
  accumulator, which makes -OoREASSOC decline it, so it stays strictly serial --
  proving the split loop reproduces the serial result.  Halt(nonzero) = failure. }
program reassoc_modref_01;
{$mode objfpc}{$H+}

{ takes the address of a local scalar and reads through it: -OoPURE rejects it,
  -OoMODREF records writes=nothing, cannot-trap; simple by-value signature so the
  reassoc addend duplicator handles the copies }
function viaaddr(x: longint): longint; noinline;
var t: longint; p: plongint;
begin t := x * x - x; p := @t; viaaddr := p^ + 1; end;

{ non-address-taken accumulator -> reassoc splits under -OoMODREF }
function sum_fast(const a: array of longint): longint;
var i, s: longint;
begin s := 0; for i := 0 to high(a) do s := s + viaaddr(a[i]); sum_fast := s; end;

{ address-taken accumulator -> reassoc declines -> strictly sequential reference }
function sum_ref(const a: array of longint): longint;
var i, s: longint; p: pointer;
begin s := 0; p := @s; for i := 0 to high(a) do s := s + viaaddr(a[i]);
  sum_ref := s; if p = nil then Halt(9); end;

var
  a: array of longint;
  i, n: longint;
begin
  for n := 0 to 40 do
    begin
      SetLength(a, n);
      for i := 0 to n - 1 do a[i] := (i mod 13) - 6;
      if sum_fast(a) <> sum_ref(a) then Halt(1);
    end;

  for n := 997 to 1000 do
    begin
      SetLength(a, n);
      for i := 0 to n - 1 do a[i] := (i mod 101) - 50;
      if sum_fast(a) <> sum_ref(a) then Halt(2);
    end;
end.
