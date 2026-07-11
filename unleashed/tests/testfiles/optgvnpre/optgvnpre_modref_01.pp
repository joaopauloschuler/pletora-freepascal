{ %OPT="-O4 -OoMODREF -OoGVNPRE" }
{ -OoGVNPRE consumes the -OoMODREF verdict: a value-numbered MEMORY read
  (gvn_mem: a deref / global / addr-taken load) available before an IMPURE call
  stays available across that call when the call's mod/ref summary proves it
  writes NO memory (modref_writes = mr_none).  Such a call may still READ global
  memory, do input, or trap -- so -OoPURE rightly refuses to prove it pure -- yet
  it cannot invalidate a memory reader, so the second occurrence is commoned to a
  reuse of the first.  This must be observationally identical to recomputing the
  read every time; a wrong reuse (keeping a value past a call that DID write the
  pointed-to memory) is caught by the killwrite kernel.  Halt(nonzero)=failure. }
program optgvnpre_modref_01;
{$mode objfpc}{$H+}

var
  fails: longint;
  garr: array[0..15] of longint;

procedure chk(got, want: longint; const msg: string);
begin
  if got <> want then
    begin
      writeln('FAIL ', msg, ' got=', got, ' want=', want);
      inc(fails);
    end;
end;

{ IMPURE: reads a global array and its division may trap, so -OoPURE proves it
  neither const nor pure; it writes NO memory, so -OoMODREF records writes=none. }
function rd(x: longint): longint; noinline;
begin
  rd := garr[x and 15] + (100 div ((x and 7) + 1));
end;

{ writes the pointed-to memory through a var parameter -> NOT write-free }
procedure wr(var y: longint); noinline;
begin
  y := y + 1;
end;

{ straight-line: a memory read, a write-free impure call, the same read again }
function straight(p: plongint; x: longint): longint; noinline;
var a, b, j: longint;
begin
  a := p^ * 3 + 1;
  j := rd(x);
  b := p^ * 3 + 1;      { reusable across rd under -OoMODREF }
  straight := a + b + j;
end;

{ loop-carried: a memory read available on entry, reused across the back-edge
  even though the body contains a write-free impure call (exercises the loop kill
  collector gvn_kill_cb: a call proven to write no memory does not clobber the
  memory-reader entries carried around the loop) }
function looped(p: plongint; n: longint): longint; noinline;
var i, acc, j, t: longint;
begin
  acc := 0; j := 0; i := 1;
  t := p^ * 3 + 1;                 { computed before the loop -> available on entry }
  while i <= n do
    begin
      j := j + rd(i);              { write-free call must not kill the mem value }
      acc := acc + (p^ * 3 + 1) + t;  { p^ reused across the back-edge under -OoMODREF }
      i := i + 1;
    end;
  looped := acc + j;
end;

{ SOUND: a call that DOES write the pointed-to memory must kill the value }
function killwrite(p: plongint): longint; noinline;
var a, b: longint;
begin
  a := p^ * 3 + 1;
  wr(p^);               { writes *p -> the second read must NOT be reused }
  b := p^ * 3 + 1;      { must recompute with the NEW *p }
  killwrite := a * 100000 + b;
end;

var
  v, n, i, refj, want, cell: longint;
begin
  fails := 0;
  for i := 0 to 15 do garr[i] := i * 7 - 11;

  for v := -20 to 20 do
    begin
      { a dedicated storage cell holds *p so the by-address calls never alias the
        for-loop counter (killwrite writes through the pointer) }
      cell := v;
      { straight: p^ is v; rd is deterministic given the fixed garr }
      chk(straight(@cell, v and 31),
          (v * 3 + 1) + (v * 3 + 1) + rd(v and 31), 'straight');

      { looped: p^ is invariant (=v), acc = n*2*(v*3+1), j = sum rd(i) }
      n := (v and 7) + 1;
      refj := 0;
      for i := 1 to n do refj := refj + rd(i);
      cell := v;
      chk(looped(@cell, n), n * 2 * (v * 3 + 1) + refj, 'looped');

      { killwrite: wr increments *p between the two reads }
      cell := v;
      want := (v * 3 + 1) * 100000 + ((v + 1) * 3 + 1);
      chk(killwrite(@cell), want, 'killwrite');
    end;

  if fails = 0 then
    writeln('ALL OK')
  else
    halt(1);
end.
