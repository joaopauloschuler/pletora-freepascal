{ %OPT=-O3 -OoMODREF -OoSTOREMOTION }
{ -OoMODREF per-parameter by-ref tracking (tasklist L257 item (e)).

  A helper with TWO by-reference parameters that writes ONLY through its first
  (the second, bound to global `h`, is never touched).  The coarse mod/ref
  summary maps over EVERY by-ref actual, so passing `h` makes the call look like
  a global writer and blocks promoting the unrelated global `g` across the loop.
  The per-formal write mask records that only formal 0 is written, so the call
  touches no global and `g` is promoted to a register across the loop.

  This fixture proves the promoted result is bit-identical to a serial reference
  (and to a variant whose helper writes BOTH params, which must NOT be promoted
  but must still compute the same value). }
program modref_byref_01;
{$mode objfpc}

var
  g, h : longint;

{ writes only formal 0 (out a); formal 1 (var b) is untouched }
procedure helper(out a: longint; var b: longint); noinline;
begin
  a := 0;
end;

{ writes both formals }
procedure hboth(var a: longint; var b: longint); noinline;
begin
  a := 0;
  b := 0;
end;

{ promotable: g accumulated every iteration, body calls the param-0-only helper }
function sm_promoted(n: longint): longint; noinline;
var
  i, tmp : longint;
begin
  tmp := -1;
  for i := 1 to n do
    begin
      g := g + i;
      helper(tmp, h);
    end;
  sm_promoted := g + tmp;
end;

{ same arithmetic, but the body call writes both params (conservative: no
  promotion) -- the value must match sm_promoted }
function sm_conservative(n: longint): longint; noinline;
var
  i, tmp : longint;
begin
  tmp := -1;
  for i := 1 to n do
    begin
      g := g + i;
      hboth(tmp, h);
    end;
  sm_conservative := g + tmp;
end;

{ closed-form serial reference: g becomes sum(1..n); tmp becomes 0 }
function sm_ref(n: longint): longint;
begin
  sm_ref := (n * (n + 1)) div 2;
end;

var
  a, b, c : longint;
begin
  g := 0; h := 9;
  a := sm_promoted(100);
  g := 0; h := 9;
  b := sm_conservative(100);
  c := sm_ref(100);
  if (a <> c) or (b <> c) then
    begin
      writeln('FAIL a=', a, ' b=', b, ' ref=', c);
      halt(1);
    end;
  writeln('OK ', a);
end.
