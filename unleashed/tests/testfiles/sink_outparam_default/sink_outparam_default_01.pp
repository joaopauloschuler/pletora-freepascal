{ %OPT=-O4 }
program sink_outparam_default_01;

{ Regression for the -OoSINK "default store sunk past an if whose only
  reference to V is a WRITE" miscompile (self-host blocker #7).

  Reduced from fpc_Val_UInt_Shortstr's tail (rtl/inc/sstrings.inc):

      code := 0;
      if (sp <= ns) and (s[sp] <> #0) then
        begin code := sp; result := 0; end;

  `code` is an OUT parameter; the default `code := 0` must execute on the
  fall-through (condition false) path.  The -O4 store-sink pass used to move
  `code := 0` INTO the then-arm, because sink_refs_sym counted the arm's
  `code := sp` -- a pure WRITE, not a read -- as the arm "consuming" code.
  With the default store sunk away, the fall-through path returned code with
  whatever value the OUT slot held on entry (in the compiler's val call, the
  20 left by the preceding int64 val), so a 10^19 literal was mis-typed
  ("Illegal type conversion Extended to QWord") and the -O4 self-host RTL
  build aborted.  Correct at -O2/-O3 and -O4 -OoNOSINK; must now be correct at
  plain -O4.  Fix: sink_refs_sym treats only genuine READS (loads without a
  bare nf_write) as uses of V, so an arm that merely overwrites V is not its
  consumer and the default store stays before the if. }

{$mode objfpc}

{ out-param whose default store precedes an if whose then-arm only writes it }
procedure compute(sp, ns: longint; ch: byte; out code: longint; out res: longint);
begin
  res := 999;
  code := 0;
  if (sp <= ns) and (ch <> 0) then
    begin
      code := sp;
      res := 0;
    end;
end;

var
  code, res: longint;
begin
  { fall-through path A: sp > ns -> condition false -> code must stay 0.
    Preset the OUT slots to a nonzero value to expose a skipped default store. }
  code := 20; res := 20;
  compute(21, 20, 55, code, res);
  if code <> 0 then halt(1);

  { fall-through path B: ch = 0 -> condition false -> code must stay 0 }
  code := 20; res := 20;
  compute(5, 20, 0, code, res);
  if code <> 0 then halt(2);

  { taken path: condition true -> code := sp }
  code := 20; res := 20;
  compute(5, 20, 55, code, res);
  if code <> 5 then halt(3);

  halt(0);
end.
