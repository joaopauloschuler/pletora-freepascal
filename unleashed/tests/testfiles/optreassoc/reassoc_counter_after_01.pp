{ %OPT=-O4 }
{ -OoREASSOC split a constant-trip reduction loop  for i:=lo to hi do s:=s+e(i)
  into K partial accumulators driven by a main+tail WHILE loop, which left the
  counter at hi+1 (or, for an empty range, at lo) rather than the for-loop's exit
  value (hi when it ran).  Only observable when the counter's exit value is live
  after the loop -- mode unleashed keeps the counter live -- so the fix declines
  reassociation unless the counter is known dead on exit.  Integer sums are exact
  under any grouping, so the result must equal the unoptimised computation. }
program reassoc_counter_after_01;
{$mode unleashed}
var g: array[0..255] of longint;
function work: longint;
var i, s: longint;
begin
  for i := 0 to 99 do g[i] := i;
  s := 0;
  for i := 0 to 99 do s := s + g[i];   { i escapes just below }
  work := s * 1000 + i;                { s=4950, i=99 -> 4950099 }
end;
begin
  if work <> 4950099 then Halt(1);
end.
