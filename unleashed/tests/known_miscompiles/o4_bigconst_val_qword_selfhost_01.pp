program o4_bigconst_val_qword_selfhost_01;
{ KNOWN -O4 SELF-HOST MISCOMPILE (self-host blocker #7; the THIRD plain-`-O4`
  codegen miscompile, distinct from and independent of blockers #5 and #6).

  With blocker #6 (unroll-and-jam of an outer-dependent inner bound) FIXED, plain
  OPT="-O4" ./rebuildu.sh no longer corrupts the heap compiling system.pp and the
  self-host cycle advances all the way to CYCLELEVEL=3, where ppc2 (the fork
  compiler self-built at -O4) rebuilds the RTL and ABORTS:

      flt_core.inc(614,1)  Warning: Range check error while evaluating constants
                           (-1 must be between 0 and 4294967295)
      flt_core.inc(1780,48) Error: Illegal type conversion: "Extended" to "QWord"
      system.inc(708,90)   Fatal: Internal error 2014091205

  flt_core.inc:1780 is `qword(10000000000000000000)` (10^19 -- larger than
  High(int64)=9223372036854775807 but <= High(qword)=18446744073709551615).

  ROOT CAUSE (isolated): the compiler types an integer literal in
  scanner.pas `texprvalue.try_parse_number`, which calls the RTL `val`:
      val(s, ic, code);        // int64  -> overflow, code<>0  (correct)
      if code<>0 then
        val(s, qc, code);      // qword  -> SHOULD be code=0, value 10^19
      if code<>0 then          //         but a miscompiled val returns code=20
        try_parse_real(s);     // -> literal wrongly typed as Extended(real)
  On x86-64 (CPU64) `val`->qword is the RTL routine fpc_Val_UInt_Shortstr
  (rtl/inc/sstrings.inc:1260).  Its overflow-recovery guard
      if prev > ValUInt(High(result) shr (bitsizeof(result)-8*DestSize) - u)
                 div ValNonZeroBase(vc.base) then dec(sp);
  is miscompiled so `prev > threshold` is wrongly TRUE, `dec(sp)` fires, the
  trailing `if (sp<=ns) and (s[sp]<>#0)` then sets Code:=sp (=20) even though the
  parsed VALUE is already the correct 10^19.  Nonzero code -> real fallback ->
  "Illegal type conversion Extended to QWord".

  SECOND-ORDER / SELF-REFERENTIAL: this is NOT reproduced by compiling val (or
  this file) with a seed-built ppcx64 at -O4 -- that codegen is correct.  It
  reproduces ONLY when BOTH hold: (a) the COMPILER doing the compiling is itself
  a fork compiler BUILT AT -O4 (the cycle's stage-2 ppc2), AND (b) it compiles
  fpc_Val_UInt_Shortstr at -O4.  Verified truth table for the `code` returned by
  val('10000000000000000000', qc):
      seed-built ppcx64,  RTL @ -O4      -> code=0   (correct)
      seed-built ppcx64,  RTL @ default  -> code=0   (correct)
      ppc2 (-O4-built),   RTL @ -O4      -> code=20  (WRONG)  <-- blocker
      ppc2 (-O4-built),   RTL @ default  -> code=0   (correct)
  So a fork -O4 optimizer pass, when applied to the compiler's OWN sources while
  building ppc2, corrupts an optimizer/codegen routine such that ppc2's -O4
  codegen then mis-lowers val's shr-by-(64-8*DestSize) / subrange-div overflow
  guard.  The seed's -O4 (upstream FPC 3.2.2 passes) does not, and ppc2 at
  default opt does not.

  MINIMAL TRIGGER INPUT is the one line below.  A plain `ppcx64 -O4` on it is
  CLEAN (the seed-built compiler's -O4 is correct); to reproduce the miscompile
  drive the two-stage self-host:
      1. build stage-1:   make -C compiler ppcx64 PP=/usr/bin/ppcx64
      2. build the -O4 RTL WITH a fork -O4 compiler and the stage-2 compiler ppc2
         against it:      make -C rtl PP=<forkO4cc> OPT="-O4"
                          make -C compiler ppcx64 PP=<stage1> OPT="-O4"
      3. ppc2 <this file>  ->  Error: Illegal type conversion "Extended" to "QWord"
  Equivalently, running val('10000000000000000000', q, code) against an RTL that
  was compiled by a fork -O4 compiler returns code=20 (should be 0). }

{$mode objfpc}
var q : qword;
begin
  q := qword(10000000000000000000);   { flt_core.inc:1780 shape; 10^19, fits qword }
  writeln(q);
end.
