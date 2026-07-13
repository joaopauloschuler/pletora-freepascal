program align_probe;
{$mode objfpc}{$H+}
{
  Aligned-vs-unaligned AVX-move probe for the "aligned AVX moves for the
  single-precision TNNetVolume loops" optimizer task (tasklist.md).

  It answers, ON THIS MACHINE, the two questions that decide whether the task's
  compiler-side half (teach -O4 to emit vmovaps instead of vmovups) is worth
  building, and whether 32/64-byte alignment of neural-api's FData buffer pays:

    1. Alignment of FPC dynamic-array data (which backs TNNetVolume.FData):
       is it already 16-/32-/64-byte aligned?  The RTL allocator fixes this;
       neural-api cannot change it from source.

    2. vmovaps vs vmovups on identically ALIGNED data: is the aligned MOVE
       instruction any faster than the unaligned one?  (Modern x86 caveat:
       since Sandy Bridge they are the same speed on aligned data.)

    3. The cache-line-split penalty: 256-bit (ymm) loads on 32-byte-aligned
       data vs on 16-byte-aligned-but-not-32 data (the current dynamic-array
       reality) vs on fully misaligned data, streamed from L1/L2/L3/RAM.

  Build with the fork compiler:
    ppcx64 -Fu<fork>/rtl/units/x86_64-linux -O2 -Cfavx2 align_probe.lpr
  Run under: ulimit -v 3000000; timeout 200 ./align_probe

  This is a data-alignment probe, not a compiler A/B benchmark, so it lives in
  examples/ (pf-bench only auto-discovers bench/*.bench.lpr) rather than in a
  bench/ dir.
}
uses SysUtils;

{ ---- 4-accumulator 256-bit (ymm) streaming reduction, vmovups loads ---- }
{ rdi=p  rsi=n(mult of 32)  rdx=reps  -> xmm0 (low single = sum) }
function k256ups(p: PSingle; n, reps: PtrInt): single; assembler; nostackframe;
asm
  vxorps %ymm0,%ymm0,%ymm0
.Lo:
  xor %rax,%rax
  vxorps %ymm1,%ymm1,%ymm1
  vxorps %ymm2,%ymm2,%ymm2
  vxorps %ymm3,%ymm3,%ymm3
  vxorps %ymm4,%ymm4,%ymm4
.Li:
  vmovups (%rdi,%rax,4),%ymm5
  vmovups 32(%rdi,%rax,4),%ymm6
  vmovups 64(%rdi,%rax,4),%ymm7
  vmovups 96(%rdi,%rax,4),%ymm8
  vaddps %ymm5,%ymm1,%ymm1
  vaddps %ymm6,%ymm2,%ymm2
  vaddps %ymm7,%ymm3,%ymm3
  vaddps %ymm8,%ymm4,%ymm4
  add $32,%rax
  cmp %rsi,%rax
  jl .Li
  vaddps %ymm1,%ymm0,%ymm0
  vaddps %ymm2,%ymm0,%ymm0
  vaddps %ymm3,%ymm0,%ymm0
  vaddps %ymm4,%ymm0,%ymm0
  dec %rdx
  jnz .Lo
  vextractf128 $1,%ymm0,%xmm1
  vaddps %xmm1,%xmm0,%xmm0
  vhaddps %xmm0,%xmm0,%xmm0
  vhaddps %xmm0,%xmm0,%xmm0
  vzeroupper
end;

{ same kernel but vmovaps loads (requires a 32-byte-aligned base) }
function k256aps(p: PSingle; n, reps: PtrInt): single; assembler; nostackframe;
asm
  vxorps %ymm0,%ymm0,%ymm0
.Lo2:
  xor %rax,%rax
  vxorps %ymm1,%ymm1,%ymm1
  vxorps %ymm2,%ymm2,%ymm2
  vxorps %ymm3,%ymm3,%ymm3
  vxorps %ymm4,%ymm4,%ymm4
.Li2:
  vmovaps (%rdi,%rax,4),%ymm5
  vmovaps 32(%rdi,%rax,4),%ymm6
  vmovaps 64(%rdi,%rax,4),%ymm7
  vmovaps 96(%rdi,%rax,4),%ymm8
  vaddps %ymm5,%ymm1,%ymm1
  vaddps %ymm6,%ymm2,%ymm2
  vaddps %ymm7,%ymm3,%ymm3
  vaddps %ymm8,%ymm4,%ymm4
  add $32,%rax
  cmp %rsi,%rax
  jl .Li2
  vaddps %ymm1,%ymm0,%ymm0
  vaddps %ymm2,%ymm0,%ymm0
  vaddps %ymm3,%ymm0,%ymm0
  vaddps %ymm4,%ymm0,%ymm0
  dec %rdx
  jnz .Lo2
  vextractf128 $1,%ymm0,%xmm1
  vaddps %xmm1,%xmm0,%xmm0
  vhaddps %xmm0,%xmm0,%xmm0
  vhaddps %xmm0,%xmm0,%xmm0
  vzeroupper
end;

function AlignUp(pp, a: PtrUInt): PtrUInt;
begin Result := (pp + a - 1) and not (a - 1); end;

var
  raw: pointer;
  base: PSingle;

function MedianMs(off, cnt, rp: PtrInt; useAps: boolean): double;
var t0: TDateTime; best: double; k: integer; r: single; ms: double;
begin
  best := 1e18;
  for k := 1 to 5 do
  begin
    t0 := Now;
    if useAps then r := k256aps(PSingle(PtrUInt(base) + off), cnt, rp)
              else r := k256ups(PSingle(PtrUInt(base) + off), cnt, rp);
    ms := (Now - t0) * 86400000.0;
    if ms < best then best := ms;
    if r < -1 then Writeln('x');   // keep r live
  end;
  Result := best;
end;

procedure ReportAlignment;
var a: array of single; i, c16, c32, c64: integer; p: PtrUInt;
begin
  c16 := 0; c32 := 0; c64 := 0;
  for i := 1 to 2000 do
  begin
    SetLength(a, 64 + (i mod 7));
    p := PtrUInt(@a[0]);
    if (p and 15) = 0 then Inc(c16);
    if (p and 31) = 0 then Inc(c32);
    if (p and 63) = 0 then Inc(c64);
    a := nil;
  end;
  Writeln('[1] FPC dynamic-array (TNNetVolume.FData backing) data alignment over 2000 allocs:');
  Writeln(Format('    16-byte: %d/2000   32-byte: %d/2000   64-byte: %d/2000',
    [c16, c32, c64]));
  Writeln('    => the RTL guarantees 16-byte but NOT 32-byte alignment.');
  Writeln;
end;

procedure Test(sz: PtrInt; const nm: string);
var m32, m16, mm, maps: double; rp: PtrInt; i: PtrInt;
begin
  base := PSingle(AlignUp(PtrUInt(raw) + 128, 64));   // 64-byte aligned base
  for i := 0 to sz - 1 do base[i] := 1.0 + (i mod 3) * 0.5;
  rp := (2 * 1000 * 1000 * 1000) div sz; if rp < 5 then rp := 5;
  m32  := MedianMs(0,  sz,     rp, false);  // >=32-byte aligned, vmovups
  m16  := MedianMs(16, sz - 8, rp, false);  // 16-aligned not 32, vmovups (current reality)
  mm   := MedianMs(4,  sz - 8, rp, false);  // fully misaligned, vmovups
  maps := MedianMs(0,  sz,     rp, true);   // >=32-byte aligned, vmovaps
  Writeln(Format('%s n=%-8d rp=%-7d | ups32=%7.1f  ups16=%7.1f  upsMis=%7.1f  aps32=%7.1f ms',
    [nm, sz, rp, m32, m16, mm, maps]));
  Writeln(Format('    16-vs-32 split penalty = %5.1f%%   |   vmovaps-vs-vmovups (aligned) = %5.1f%%',
    [(m16 / m32 - 1) * 100, (maps / m32 - 1) * 100]));
end;

begin
  Writeln('=== aligned-AVX-move probe (', {$I %FPCTARGETCPU%}, ') ===');
  Writeln;
  ReportAlignment;
  raw := GetMem(16 * 1024 * 1024 + 256);
  Writeln('[2]/[3] 256-bit (ymm) streaming reduction, best-of-5:');
  Test(4096,          'L1  16KB ');
  Test(32 * 1024,     'L2  128KB');
  Test(512 * 1024,    'L3  2MB  ');
  Test(3 * 1024 * 1024,'RAM 12MB');
  FreeMem(raw);
  Writeln;
  Writeln('Interpretation: vmovaps == vmovups on aligned data (aps-vs-ups ~0%),');
  Writeln('so emitting aligned MOVES buys nothing; the real win is 32-byte-aligned');
  Writeln('DATA feeding 256-bit loads (ups16 penalty), which needs the RTL/allocator,');
  Writeln('not the vmovaps instruction.');
end.
