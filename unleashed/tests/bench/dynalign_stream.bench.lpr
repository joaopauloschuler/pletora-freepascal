{ dynalign_stream.bench — 256-bit (ymm) streaming reduction over a DYNAMIC
  ARRAY's element data, the workload that measures the pletora/freepascal RTL
  64-byte over-alignment of dynamic-array data (tasklist.md L260, option (i)).

  The kernel is a 4-accumulator vmovups ymm reduction (identical to
  examples/align_probe.lpr's k256ups) run over @a[0] of a `array of Single`
  sized to live in L2/L3.  vmovups works on ANY alignment, so the ONLY thing
  that changes between an A build (RTL without the alignment, @a[0] 16-aligned)
  and a B build (fork RTL, @a[0] 64-aligned) is the cache-line-split behaviour
  of the 256-bit loads — exactly the +72.5% (L2) / +24.7% (L3) effect the probe
  measured.  Same data, same instructions, so the checksum is identical across
  builds and pf-bench's A/B gate compares pure placement effect.

  A/B usage (stock-RTL vs fork-aligned-RTL, same compiler):
    pf-bench ab --compiler-a <ppcx64> --compiler-b <ppcx64> \
      --flags=-O2 --flags-a=-Fu/tmp/rtl_stock --flags-b=-Fu/tmp/rtl_aligned \
      --filter dynalign_stream

  Sized so one run is ~0.2-2 s at scale 1. }
program dynalign_stream_bench;

{$mode objfpc}{$H+}

uses
  SysUtils;

type
  PSingle = ^Single;

const
  N        = 65536;   { singles -> 256 KiB, L2/L3 resident; multiple of 32 }
  BASE_REPS = 2600;

{ 4-accumulator 256-bit (ymm) streaming reduction, vmovups loads.
  rdi=p  rsi=n(mult of 32)  rdx=reps  -> xmm0 (low single = sum) }
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

function Scale: Integer;
var s: string; v: Integer;
begin
  s := GetEnvironmentVariable('PF_BENCH_SCALE');
  if (s = '') or not TryStrToInt(s, v) or (v < 1) then v := 1;
  Result := v;
end;

var
  a: array of Single;
  i, reps: Integer;
  seed: LongWord;
  sum: single;
begin
  SetLength(a, N);
  seed := $12345;
  for i := 0 to N - 1 do
  begin
    seed := seed * 1103515245 + 12345;
    a[i] := ((seed shr 16) and $FFFF) / 65536.0 - 0.5;
  end;
  { report the achieved element-data alignment on stderr (diagnostic only) }
  Writeln(StdErr, Format('dynalign_stream: @a[0] mod 64 = %d', [PtrUInt(@a[0]) mod 64]));

  reps := BASE_REPS div Scale;
  if reps < 1 then reps := 1;
  sum := k256ups(@a[0], N, reps);

  { deterministic checksum: the sum is identical every rep, so scale only
    changes the repeat count; round to make it build-independent }
  Writeln(Format('dynalign_stream n=%d crc=%.6f', [N, Round(sum * 1000) / 1000]));
end.
