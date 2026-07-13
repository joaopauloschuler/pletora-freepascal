{ %OPT="-O2 -OoDEVIRT" }
{ -OoDEVIRT must NOT devirtualize a call whose receiver is not provably
  monomorphic, and dispatch must remain correct. Three defeat cases, each
  exercised so the runtime distinguishes right from wrong dispatch:
    * two constructors of DIFFERENT classes reaching the call site;
    * reassignment to a different class between construction and the call;
    * receiver passed by var to a routine that rebinds it.
  In every case the virtual call must reach the object's REAL dynamic type. }
program optdevirt_polymorphic_01;
{$mode objfpc}{$H+}

type
  TShape = class
    function Area: longint; virtual;
  end;
  TSquare = class(TShape)
    S: longint;
    constructor Create(s_: longint);
    function Area: longint; override;
  end;
  TBox = class(TShape)
    W,H: longint;
    constructor Create(w_,h_: longint);
    function Area: longint; override;
  end;

function TShape.Area: longint; begin Result:=-1; end;
constructor TSquare.Create(s_: longint); begin S:=s_; end;
function TSquare.Area: longint; begin Result:=S*S; end;
constructor TBox.Create(w_,h_: longint); begin W:=w_; H:=h_; end;
function TBox.Area: longint; begin Result:=W*H; end;

{ two different constructed classes reach the call -> not provable }
function branchy(square: boolean): longint;
var sh: TShape;
begin
  if square then sh := TSquare.Create(5)
            else sh := TBox.Create(3,4);
  Result := sh.Area;
  sh.Free;
end;

{ reassigned to a different class before the call -> not provable }
function reassigned: longint;
var sh: TShape;
begin
  sh := TSquare.Create(2);
  sh.Free;
  sh := TBox.Create(6,7);
  Result := sh.Area;           { must be 42, the TBox }
  sh.Free;
end;

{ receiver rebound through a var parameter -> not provable }
procedure rebind(var sh: TShape);
begin
  sh := TBox.Create(10,10);
end;

function viavar: longint;
var sh: TShape;
begin
  sh := TSquare.Create(9);     { would give 81 if wrongly devirtualized }
  rebind(sh);                  { now a TBox 10x10 -> 100 }
  Result := sh.Area;
  sh.Free;
end;

begin
  if branchy(true)  <> 25  then Halt(1);
  if branchy(false) <> 12  then Halt(2);
  if reassigned     <> 42  then Halt(3);
  if viavar         <> 100 then Halt(4);
end.
