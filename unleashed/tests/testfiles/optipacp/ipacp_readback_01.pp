{ %OPT="-O2 -OoIPACP" }
{ -OoIPACP result read-back: a specialized clone whose body reads its own
  function result (an accumulator that has no `exit`) must still place the
  result in the return location -- this exercises the funcret reference-count
  fix-up in the clone remap.  Also covers boolean and enum specialized
  parameters and a routine that reads Result via both the function name and
  the Result keyword. }
program ipacp_readback_01;
{$mode objfpc}{$H+}

type TMode = (mAdd, mMul, mMax);

var acc: longint = 0;

{ reads its own result, no exit: funcret refs must be fixed up in the clone }
function Grow(a, k: longint): longint;
begin
  Grow := a;
  if k > 0 then
    Grow := Grow + k;
  if k > 10 then
    Grow := Grow * 2;
end;

function refGrow(a, k: longint): longint;
begin
  refGrow := a;
  if k > 0 then refGrow := refGrow + k;
  if k > 10 then refGrow := refGrow * 2;
end;

{ enum-specialized parameter driving a case, result read back via Result }
function Combine(a, b: longint; m: TMode): longint;
begin
  case m of
    mAdd: Result := a + b;
    mMul: Result := a * b;
    mMax: if a > b then Result := a else Result := b;
  else
    Result := 0;
  end;
  if m = mMul then
    Result := Result + 1;   { reads Result back }
end;

function refCombine(a, b: longint; m: TMode): longint;
begin
  case m of
    mAdd: refCombine := a + b;
    mMul: refCombine := a * b;
    mMax: if a > b then refCombine := a else refCombine := b;
  else refCombine := 0;
  end;
  if m = mMul then refCombine := refCombine + 1;
end;

{ boolean-specialized parameter }
procedure Accumulate(v: longint; doDouble: boolean);
begin
  if doDouble then
    acc := acc + v * 2
  else
    acc := acc + v;
end;

var a, b, refacc: longint;
begin
  for a := -5 to 15 do
    begin
      if Grow(a, 5) <> refGrow(a, 5) then Halt(1);   { clone k=5 }
      if Grow(a, 12) <> refGrow(a, 12) then Halt(2); { clone k=12 }
    end;

  for a := -3 to 3 do
    for b := -3 to 3 do
      begin
        if Combine(a, b, mAdd) <> refCombine(a, b, mAdd) then Halt(3);
        if Combine(a, b, mMul) <> refCombine(a, b, mMul) then Halt(4);
        if Combine(a, b, mMax) <> refCombine(a, b, mMax) then Halt(5);
      end;

  acc := 0; refacc := 0;
  for a := 1 to 10 do
    begin
      Accumulate(a, true);  refacc := refacc + a * 2;
      Accumulate(a, false); refacc := refacc + a;
    end;
  if acc <> refacc then Halt(6);

  Halt(0);
end.
