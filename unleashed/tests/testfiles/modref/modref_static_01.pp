{ %OPT=-O3 -OoMODREF -OoSTOREMOTION }
{ -OoMODREF per-location (per-static-variable) aliasing precision (tasklist
  L256 item (d)).

  Loop store motion holds a promoted global in a register across the whole loop
  and writes it back once afterwards, so a body call that writes that global
  would be lost.  The coarse mod/ref summary blocked promotion whenever a body
  call wrote ANY global; the per-static summary records WHICH statics a call
  writes, so:

    * sm_disjoint promotes `g` across a loop whose body calls a helper that
      writes only the UNRELATED static `h` -- the register copy of `g` is never
      clobbered, and the closed-form sum is reproduced exactly;

    * sm_samewriter's body call writes the promoted `g` itself, so it must NOT
      be promoted; the helper's writes have to be reflected in the result.  If
      the per-static check were unsound and promoted it anyway, `g` would lose
      every helper write and the value would be wrong -- this fixture halts(1)
      on that mismatch.

  Bit-exact: both results are checked against closed-form references. }
program modref_static_01;
{$mode objfpc}

var
  g, h : longint;

{ writes only the disjoint static h (never touches g) }
procedure wh; noinline;
begin
  h := h + 3;
end;

{ writes the accumulator global g itself }
procedure wg; noinline;
begin
  g := g + 100;
end;

{ promotable: body call writes only h -> g may live in a register }
function sm_disjoint(n: longint): longint; noinline;
var
  i : longint;
begin
  for i := 1 to n do
    begin
      g := g + i;
      wh;
    end;
  sm_disjoint := g;
end;

{ NOT promotable: body call writes g -> promotion would drop wg's writes }
function sm_samewriter(n: longint): longint; noinline;
var
  i : longint;
begin
  for i := 1 to n do
    begin
      g := g + i;
      wg;
    end;
  sm_samewriter := g;
end;

var
  a, b, refa, refb : longint;
begin
  { sm_disjoint: g becomes sum(1..100)=5050; h becomes 3*100=300 }
  g := 0; h := 0;
  a := sm_disjoint(100);
  refa := (100 * 101) div 2;             { 5050 }
  { sm_samewriter: g becomes sum(1..100) + 100*100 = 5050 + 10000 = 15050 }
  g := 0;
  b := sm_samewriter(100);
  refb := ((100 * 101) div 2) + 100 * 100; { 15050 }
  if (a <> refa) or (b <> refb) or (h <> 300) then
    begin
      writeln('FAIL a=', a, ' (', refa, ') b=', b, ' (', refb, ') h=', h);
      halt(1);
    end;
  writeln('OK ', a, ' ', b);
end.
