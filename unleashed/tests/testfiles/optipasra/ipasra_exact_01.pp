program ipasra_exact_01;
{ Bit-exact runtime fixture for -OoIPASRA (interprocedural scalar replacement of
  aggregates, part (b) of the gcc -fipa-sra port).

  A const two-field record parameter (and a const three-field one) is passed to
  noinline helpers whose bodies only READ the fields.  With -OoIPASRA the callers
  are rebuilt to split-parameter clones (const record -> by-value scalars); the
  observable output AND the side-effect (helper-call) counter must be byte-for-
  byte identical to the un-split build.  Distinct field values catch any field
  mis-ordering at the rebuilt call site. }
{$mode objfpc}{$Q+}{$R+}
type
  TPair = record x: longint; y: longint; end;
  TTriple = record a: longint; b: double; c: longint; end;
var
  calls: longint = 0;

function pair_eval(const p: TPair; k: longint): longint; noinline;
begin
  inc(calls);
  { asymmetric in x/y so a swapped split is observable }
  pair_eval := p.x * 100 + p.y * 3 - k;
end;

function triple_eval(const t: TTriple; k: longint): double; noinline;
begin
  inc(calls);
  triple_eval := t.a * 10.0 + t.b - t.c * k;
end;

var
  p: TPair;
  t: TTriple;
  i: longint;
  s: longint;
  d: double;
begin
  p.x := 5; p.y := 9;
  t.a := 4; t.b := 1.5; t.c := 2;
  s := 0;
  d := 0.0;
  for i := 1 to 7 do
    begin
      s := s + pair_eval(p, i);
      d := d + triple_eval(t, i);
    end;
  writeln('s=', s);
  writeln('d=', d:0:4);
  writeln('calls=', calls);
end.
