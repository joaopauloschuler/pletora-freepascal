{ %OPT="-O4 -Sew" }
program loopfill_dfa_01;

{ Regression for the -O4 (DFA) "does not seem to be initialized" false positive
  on a local array filled in one counted for-loop and read in later for-loops
  (self-host blocker; reduced from compiler/optfinalvalue.pas's try_transform,
  local var `accs`, whose record holds tsym/tnode/tdef pointer fields).

  The DFA models a partial element write arr[i]:=x as a full def of arr, but the
  for-node liveness re-adds the successor's whole life because the loop body
  "might run 0 times", so the fill loop's def never reaches the read loop and
  arr is spuriously reported uninitialized.  (The pointer fields matter: an
  all-integer record is regable and dodges the note; the compiler's own taccrec
  carries reference fields, so this test reproduces that exact shape.)

  It is warning-only -- codegen keeps arr initialised -- but the self-host
  bootstrap builds with -Sew, so the note becomes a fatal error.  Compiled here
  with -Sew: if the false positive comes back, the note is treated as an error
  and this test fails to compile.  It exercises every shape the fix must cover:
  the fill via an out-parameter, an inner subrange read arr[j] (j in 0..k-1)
  inside the fill loop, and separate reader loops whose bounds are identical to
  the fill loop. }

{$mode objfpc}

const MAXACC = 64;

type
  taccrec = record
    sym : pointer; cexpr : pointer; negative, isptr : boolean; sdef : pointer;
  end;
  tsymarr = array[0..MAXACC] of pointer;

function match(i : integer; out acc : taccrec) : boolean;
begin
  acc.sym := pointer(ptruint(i));
  acc.cexpr := nil;
  acc.negative := (i and 1) = 0;
  acc.isptr := false;
  acc.sdef := nil;
  match := i <> 3;                     { i=3 would be rejected }
end;

function is_inv(e : pointer; var f : tsymarr; nf : integer) : boolean;
begin
  is_inv := e = nil;
end;

function test(cnt : integer) : ptruint;
var
  k, j : integer;
  accs : array[0..MAXACC-1] of taccrec;
  forbidden : tsymarr;
  nforbidden : integer;
begin
  test := 0;
  if (cnt <= 0) or (cnt > MAXACC) then
    exit;
  forbidden[0] := nil;
  nforbidden := 1;

  { fill loop: writes accs[k] via an out parameter, and reads the already-filled
    prefix accs[j] (j in 0..k-1, a subrange of the fill range) }
  for k := 0 to cnt-1 do
    begin
      if not match(k, accs[k]) then
        exit;
      for j := 0 to k-1 do
        if accs[j].sym = accs[k].sym then
          exit;
      forbidden[nforbidden] := accs[k].sym;
      inc(nforbidden);
    end;

  { reader loop, bounds identical to the fill loop }
  for k := 0 to cnt-1 do
    if assigned(accs[k].cexpr) and not is_inv(accs[k].cexpr, forbidden, nforbidden) then
      exit;

  { another reader loop, bounds identical to the fill loop }
  for k := 0 to cnt-1 do
    if accs[k].negative then
      inc(test, ptruint(accs[k].sym));
end;

var
  r : ptruint;
begin
  { cnt=3: sym=0,1,2; negative for i=0,2 -> add sym 0 and 2 -> total 2 }
  r := test(3);
  if r <> 2 then
    begin
      writeln('FAIL: got ', r, ' expected 2');
      halt(1);
    end;
  writeln('ok ', r);
end.
