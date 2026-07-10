{ %OPT="-O2 -OoDEVIRT" }
{ -OoDEVIRT provable-receiver devirtualization must preserve dispatch. A local
  variable declared of an ANCESTOR type but constructed as a DESCENDANT must
  still call the descendant's override after devirtualization (the CONSTRUCTED
  type is used, not the declared type). Covers a three-level hierarchy where
  each level overrides, an intermediate level that does NOT override (so the
  vmt slot resolves to the inherited implementation), and a method that reads
  instance fields (proving self is passed correctly, not just the name). }
program optdevirt_descendant_01;
{$mode objfpc}{$H+}

type
  TAnimal = class
    Legs: longint;
    constructor Create(l: longint);
    function Sound: string; virtual;
    function LegCount: longint; virtual;
  end;

  TDog = class(TAnimal)                 { overrides Sound, inherits LegCount }
    function Sound: string; override;
  end;

  TPuppy = class(TDog)                  { overrides Sound again }
    function Sound: string; override;
  end;

  TSnake = class(TAnimal)              { overrides both }
    function Sound: string; override;
    function LegCount: longint; override;
  end;

constructor TAnimal.Create(l: longint); begin Legs:=l; end;
function TAnimal.Sound: string; begin Result:='...'; end;
function TAnimal.LegCount: longint; begin Result:=Legs; end;
function TDog.Sound: string; begin Result:='woof'; end;
function TPuppy.Sound: string; begin Result:='yip'; end;
function TSnake.Sound: string; begin Result:='hiss'; end;
function TSnake.LegCount: longint; begin Result:=0; end;

{ declared TAnimal, constructed TDog -> devirt to TDog.Sound, TAnimal.LegCount }
function dog_sound: string;
var a: TAnimal;
begin
  a := TDog.Create(4);
  Result := a.Sound;            { must be 'woof' }
  if a.LegCount <> 4 then Halt(11);
  a.Free;
end;

{ declared TAnimal, constructed TPuppy -> devirt to TPuppy.Sound }
function puppy_sound: string;
var a: TAnimal;
begin
  a := TPuppy.Create(4);
  Result := a.Sound;            { must be 'yip' }
  a.Free;
end;

{ declared TDog, constructed TSnake is NOT valid (unrelated); use TAnimal }
function snake_legs: longint;
var a: TAnimal;
begin
  a := TSnake.Create(99);       { Legs set to 99, but LegCount override -> 0 }
  Result := a.LegCount;         { must be 0, proving the override, not field }
  a.Free;
end;

begin
  if dog_sound   <> 'woof' then Halt(1);
  if puppy_sound <> 'yip'  then Halt(2);
  if snake_legs  <> 0      then Halt(3);
end.
