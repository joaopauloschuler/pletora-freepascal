{ %OPT="-O4 -OoMODREF -OoREASSOC" }
{ -OoREASSOC addend duplication with an OPEN-ARRAY-parameter call in the addend.

  A reduction  acc := acc + pick(tab, a[i])  where `pick` takes a `const array
  of longint` (open array) is admissible for splitting only under -OoMODREF:
  -OoPURE's purity analysis rejects open-array / managed / hidden parameters
  outright, so a call with an open-array parameter never reaches the PURE fence,
  while -OoMODREF proves `pick` writes NO memory and cannot trap.  Duplicating
  the addend with a shifted counter must PRESERVE the fixed-array->open-array
  conversion on each copy (the fixed `tab` is bound to the open-array parameter
  with a boundary conversion + a hidden runtime high para); reassoc_reset_cb
  leaves the already-firstpassed call's expanded argument list intact so the copy
  no longer re-typechecks the array actual as its element type
  ("Incompatible types: got Array Of LongInt expected LongInt").

  Correctness must hold whether or not the split fires: an integer sum is exact
  under any grouping.  sum_ref takes the address of its accumulator, which makes
  -OoREASSOC decline it, so it stays strictly serial -- proving the split loop
  reproduces the serial result.  Halt(nonzero) = failure. }
program reassoc_modref_02;
{$mode objfpc}{$H+}

var
  tab: array[0..7] of longint;

{ open-array parameter, reads only its argument -> writes nothing, non-trapping;
  -OoPURE cannot admit the open-array signature, only -OoMODREF can }
function pick(const v: array of longint; k: longint): longint; noinline;
begin pick := v[k and 7]; end;

{ non-address-taken accumulator -> reassoc splits under -OoMODREF }
function sum_fast(const a: array of longint): longint;
var i, s: longint;
begin s := 0; for i := 0 to high(a) do s := s + pick(tab, a[i]); sum_fast := s; end;

{ address-taken accumulator -> reassoc declines -> strictly sequential reference }
function sum_ref(const a: array of longint): longint;
var i, s: longint; p: pointer;
begin s := 0; p := @s; for i := 0 to high(a) do s := s + pick(tab, a[i]);
  sum_ref := s; if p = nil then Halt(9); end;

var
  a: array of longint;
  i, n: longint;
begin
  for i := 0 to 7 do tab[i] := i * i - 3;

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
