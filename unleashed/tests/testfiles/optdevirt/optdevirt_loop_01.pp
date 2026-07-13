{ %OPT="-O2 -OoDEVIRT" }
{ -OoDEVIRT across control flow: a receiver constructed ONCE before a loop and
  never reassigned inside it stays provably monomorphic on every iteration (the
  loop body kills no fact about it), so its many virtual calls devirtualize --
  the neural-api "call a virtual method per iteration on a fixed object" shape.
  Result must equal the override's accumulation, and a sealed class / final
  method receiver (which the WPO pass would also devirtualize) is included. }
program optdevirt_loop_01;
{$mode objfpc}{$H+}

type
  TStep = class
    function Delta: longint; virtual;
  end;
  TInc = class(TStep)
    function Delta: longint; override;
  end;
  {$ifdef fpc}
  TSealedInc = class sealed (TStep)
    function Delta: longint; override; final;
  end;
  {$endif}

function TStep.Delta: longint; begin Result:=0; end;
function TInc.Delta: longint; begin Result:=2; end;
function TSealedInc.Delta: longint; begin Result:=3; end;

function accumulate(iters: longint): longint;
var s: TStep; i, acc: longint;
begin
  s := TInc.Create;            { constructed once, called in the loop below }
  acc := 0;
  for i := 1 to iters do
    acc := acc + s.Delta;      { devirt to TInc.Delta on every iteration }
  s.Free;
  Result := acc;
end;

function accumulate_sealed(iters: longint): longint;
var s: TStep; i, acc: longint;
begin
  s := TSealedInc.Create;
  acc := 0;
  for i := 1 to iters do
    acc := acc + s.Delta;      { devirt to TSealedInc.Delta }
  s.Free;
  Result := acc;
end;

begin
  if accumulate(1000)        <> 2000 then Halt(1);
  if accumulate_sealed(1000) <> 3000 then Halt(2);
  if accumulate(0)           <> 0    then Halt(3);
end.
