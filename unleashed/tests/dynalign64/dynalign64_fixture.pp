{ Runtime fixture for the OPT-IN 64-byte over-alignment of dynamic-array
  element data (rtl/inc/dynarr.inc, -dFPC_DYNARRAY_ALIGN64; tasklist.md L260).

  Compiled against an RTL built WITH the define, every @a[0] must be 64-aligned,
  while Length/High/data semantics stay correct across SetLength grow/shrink,
  copy-on-write split, empty, managed elements, Copy, Insert, Delete and concat.
  Built against the default (stock) RTL it instead reports alignment FAILURES,
  so it doubles as a discriminator that the switch actually gates placement.

  Manual verification (the switch is a compile-time RTL flag, so it needs its
  own RTL build; there is no in-tree check script because the RTL Makefile's
  clean target wipes the shared tree units):

    fork=<...>/pletora/freepascal
    ard=$(mktemp -d)
    make -C "$fork/rtl" clean all FPC="$fork/compiler/ppcx64" \
         OPT="-dFPC_DYNARRAY_ALIGN64 -FU$ard" -j8
    "$fork/compiler/ppcx64" -Fu"$ard" -O2 -gh -o/tmp/fx dynalign64_fixture.pp
    ( ulimit -v 3000000; timeout 60 /tmp/fx )        # expect: ALL OK + 0 unfreed
    # then restore the tree RTL (the -FU build + clean emptied it):
    make -C "$fork/rtl" clean all FPC="$fork/compiler/ppcx64" -j8 }
program dynalign_test;
{$mode objfpc}{$h+}
type
  TRec = record a,b,c : double; tag : ansistring; end;
var
  fails : integer = 0;

function IntToStr(v : ptruint) : string;
begin str(v,result); end;

procedure chk(cond : boolean; const msg : string);
begin
  if not cond then begin writeln('FAIL: ',msg); inc(fails); end;
end;

procedure chkalign(p : pointer; const msg : string);
begin
  chk((p<>nil) and (PtrUInt(p) mod 64 = 0), msg+' align='+IntToStr(PtrUInt(p) mod 64));
end;

var
  ab : array of byte;
  asg : array of single;
  adb : array of double;
  arc : array of TRec;
  ast : array of ansistring;
  i : integer;
  b2,b3 : array of byte;
begin
  { --- alignment for several element sizes --- }
  SetLength(ab, 1);   chkalign(@ab[0], 'byte[1]');
  SetLength(ab, 7);   chkalign(@ab[0], 'byte[7]');
  SetLength(ab, 1000);chkalign(@ab[0], 'byte[1000]');
  SetLength(asg, 3);  chkalign(@asg[0], 'single[3]');
  SetLength(asg, 257);chkalign(@asg[0], 'single[257]');
  SetLength(adb, 5);  chkalign(@adb[0], 'double[5]');
  SetLength(adb, 4096);chkalign(@adb[0], 'double[4096]');
  SetLength(arc, 10); chkalign(@arc[0], 'rec[10]');
  SetLength(ast, 8);  chkalign(@ast[0], 'ansistr[8]');

  { --- SetLength grow preserves data & realigns --- }
  SetLength(adb, 4);
  for i:=0 to 3 do adb[i]:=i*1.5;
  SetLength(adb, 4000);
  chkalign(@adb[0], 'double grow realign');
  for i:=0 to 3 do chk(adb[i]=i*1.5, 'grow preserved '+IntToStr(i));
  for i:=4 to 3999 do chk(adb[i]=0.0, 'grow zeroed '+IntToStr(i));

  { --- SetLength shrink preserves data --- }
  SetLength(adb, 2);
  chkalign(@adb[0], 'double shrink realign');
  chk((adb[0]=0.0) and (adb[1]=1.5), 'shrink preserved');

  { --- copy-on-write split: SetLength on a shared array uniquifies --- }
  SetLength(b2, 5);
  for i:=0 to 4 do b2[i]:=i+10;
  b3:=b2;                 { shared, refcount 2 }
  chk(pointer(b3)=pointer(b2), 'COW shares before setlength');
  SetLength(b3, 5);       { refcount<>1 -> unique aligned copy, same length }
  chkalign(@b3[0], 'COW copy align');
  chk(pointer(b3)<>pointer(b2), 'COW split pointers');
  for i:=0 to 4 do chk(b3[i]=i+10, 'COW copy preserved '+IntToStr(i));
  b3[2]:=99;
  chk(b2[2]=12, 'COW original untouched after split');
  chk(b3[2]=99, 'COW copy written');

  { --- empty --- }
  SetLength(adb, 0);
  chk(adb=nil, 'empty is nil');
  chk(Length(adb)=0, 'empty length 0');

  { --- managed element correctness --- }
  SetLength(ast, 3);
  ast[0]:='hello'; ast[1]:='world'; ast[2]:='!';
  chkalign(@ast[0], 'ansistr align');
  SetLength(ast, 6);       { grow: old strings preserved, new empty }
  chk(ast[0]='hello', 'managed grow preserved 0');
  chk(ast[2]='!', 'managed grow preserved 2');
  chk(ast[5]='', 'managed grow new empty');
  SetLength(ast, 1);       { shrink: finalizes 1..5 }
  chk(ast[0]='hello', 'managed shrink preserved');
  chk(Length(ast)=1, 'managed shrink length');

  { --- Copy / Insert / Delete / concat --- }
  SetLength(ab, 6);
  for i:=0 to 5 do ab[i]:=i;
  b2:=Copy(ab, 1, 3);
  chkalign(@b2[0], 'Copy align');
  chk((Length(b2)=3) and (b2[0]=1) and (b2[2]=3), 'Copy values');

  b2:=nil; SetLength(b2,3); b2[0]:=1;b2[1]:=2;b2[2]:=3;
  Insert(byte(9), b2, 1);
  chkalign(@b2[0], 'Insert align');
  chk((Length(b2)=4) and (b2[0]=1) and (b2[1]=9) and (b2[3]=3), 'Insert values');

  Delete(b2, 1, 1);
  chkalign(@b2[0], 'Delete align');
  chk((Length(b2)=3) and (b2[1]=2), 'Delete values');

  b3:=nil; SetLength(b3,2); b3[0]:=7;b3[1]:=8;
  b2:=concat(b2,b3);
  chkalign(@b2[0], 'concat align');
  chk((Length(b2)=5) and (b2[4]=8) and (b2[0]=1), 'concat values');

  if fails=0 then writeln('ALL OK')
  else begin writeln(fails,' FAILURES'); halt(1); end;
end.
