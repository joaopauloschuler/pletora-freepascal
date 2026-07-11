{ %OPT=-OoMODREF -OoDEADSTORE -OoSTOREMOTION }
{ Bit-exact runtime fixture for -OoMODREF.  The mod/ref summary and the barrier
  relaxations it drives (field/element dead-store elimination, loop store
  motion) are optimizations: they must never change the observable result.
  Every value below must be identical whether or not -OoMODREF is active, so
  this test belongs to the byte-identical suite baseline under both a plain run
  and a -OoMODREF-forced run.  It exercises the motivating shapes:
   * a helper that writes only its own out parameter (a disjoint summary),
   * a helper that writes a global (unknown-global write),
   * a dead field/element store across such calls,
   * a global written every iteration of a loop whose body calls a locals-only
     helper (store-motion promotion). }
program modref_bitexact_01;

{$mode objfpc}{$Q-}{$R-}

type
  TArr = array[0..3] of longint;

var
  g: longint;
  sg: TArr;

{ impure, writes only its own out parameter }
procedure mfill(out y: longint); noinline;
begin
  y := 7;
end;

{ impure, writes a global }
procedure mwglob(x: longint); noinline;
begin
  g := g + x;
end;

{ dead local field store across a disjoint (out-param-writer) call: the a[0]:=1
  is dead and may be removed, but t gets 7 from mfill }
function kdisjoint: longint; noinline;
var
  a: TArr;
  t: longint;
begin
  a[0] := 1; a[1] := 11; a[2] := 12; a[3] := 13;
  mfill(t);
  a[0] := 20;
  result := a[0] + a[1] + a[2] + a[3] + t;   { 20+11+12+13+7 = 63 }
end;

{ dead static store across a global-writing call: the sg[0]:=1 is observable to
  nothing here but must stay correct; mwglob mutates g }
function kglobal(v: longint): longint; noinline;
begin
  g := 0;
  sg[0] := 1; sg[1] := 21; sg[2] := 22; sg[3] := 23;
  mwglob(v);
  sg[0] := 40;
  result := sg[0] + sg[1] + sg[2] + sg[3] + g;  { 40+21+22+23+v }
end;

{ store-motion: g written every iteration; the body calls the locals-only sink }
function loopsum(n: longint): longint; noinline;
var
  i, tmp: longint;
begin
  g := 0;
  tmp := 0;
  for i := 1 to n do
    begin
      g := g + i;
      mfill(tmp);
    end;
  result := g + tmp;   { (n*(n+1) div 2) + 7 }
end;

procedure check(got, want, id: longint);
begin
  writeln(id, ': ', got);
  if got <> want then
    begin
      writeln('FAIL check ', id, ': got ', got, ' want ', want);
      halt(id);
    end;
end;

begin
  check(kdisjoint, 63, 1);         { 20+11+12+13+7 }
  check(kglobal(5), 111, 2);       { 40+21+22+23+5 }
  check(loopsum(10), 62, 3);       { 55 + 7 }
  writeln('OK');
end.
