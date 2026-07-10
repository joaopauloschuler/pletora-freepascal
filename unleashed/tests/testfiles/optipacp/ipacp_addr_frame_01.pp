{ %OPT=-O4 -OoIPACP }
{ -OoIPACP cloning a routine whose body takes the ADDRESS of a frame variable
  used to internalerror 2006111510: the clone's freshly-built symbol never had
  its "address taken -> must live in memory" property (addr_taken / varregable)
  re-derived, so the register allocator kept it in a register and the code
  generator failed taking its address.  Fixed by re-running make_not_regable on
  the clone's own symbols after the load-remap.  Two constant call sites force
  two clones; both must compile and run correctly. }
program ipacp_addr_frame_01;
{$mode unleashed}
procedure bump(p: plongint; k: longint); begin inc(p^, k); end;
function work(n: longint): longint;
var x, i: longint;
begin
  x := 0;
  for i := 0 to n - 1 do inc(x);   { n is a constant at each clone -> constant trip }
  bump(@x, 100);                   { address of a frame local }
  work := x;
end;
begin
  if work(10) <> 110 then Halt(1);
  if work(3)  <> 103 then Halt(2);
end.
