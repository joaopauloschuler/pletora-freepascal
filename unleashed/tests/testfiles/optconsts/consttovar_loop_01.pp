{ %OPT="-Cg -OoCONSTS" }
{$mode objfpc}
{ Regression: -OoCONSTS (do_consttovar) promotes the PIC/GOT addresses of the
  two global tables into register temps. Without a trailing ttempdeletenode
  (whose codegen emits the a_reg_sync markers), the register allocator ends the
  temps' live ranges at their last textual use inside the loop body and hands
  the registers out as scratch in the other case arm -- so the next loop
  iteration stores through a clobbered base register (address $41 = 'A').
  This is the exact shape of initupperlower in the compiler's own cutils.pas,
  which made a compiler built with OPT="-OoCONSTS" (or any set containing it,
  e.g. plain -O2 in this fork) crash at startup. }
program consttovar_loop_01;

var
  lowertbl, uppertbl: array[char] of char;

procedure initupperlower;
var
  c: char;
begin
  for c := #0 to #255 do
    begin
      lowertbl[c] := c;
      uppertbl[c] := c;
      case c of
        'A'..'Z':
          lowertbl[c] := char(byte(c) + 32);
        'a'..'z':
          uppertbl[c] := char(byte(c) - 32);
      end;
    end;
end;

begin
  initupperlower;
  if (lowertbl['A'] <> 'a') or (uppertbl['a'] <> 'A') or
     (lowertbl['0'] <> '0') or (uppertbl['~'] <> '~') or
     (lowertbl['z'] <> 'z') or (uppertbl['Z'] <> 'Z') then
    begin
      writeln('FAIL');
      halt(1);
    end;
  writeln('OK');
end.
