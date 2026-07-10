{ %OPT=-O4 }
{ A constant-trip counted for-loop that -OoLOOPUNROLL fully unrolls (getridoffor)
  used to DROP the loop counter -- its reads were rewritten to constants and the
  for-node removed -- so a post-loop read of an ESCAPING counter (mode unleashed
  keeps the counter live across loop exit) saw garbage instead of the loop's exit
  value.  Fixed by restoring i := hi after the unrolled block when the exit value
  is not known dead.  A zero-trip loop must leave the counter unchanged, exactly
  as a real for-loop would. }
program unroll_counter_after_01;
{$mode unleashed}
var g: array[0..63] of longint;
function ran: longint;          { loop ran -> counter must be hi (9) }
var i: longint;
begin
  i := -1;
  for i := 0 to 9 do g[i] := i;
  ran := i;
end;
function empty: longint;        { zero-trip -> counter unchanged (pre-value 42) }
var i: longint;
begin
  i := 42;
  for i := 0 to -1 do g[0] := i;
  empty := i;
end;
begin
  if ran <> 9 then Halt(1);
  if empty <> 42 then Halt(2);
end.
