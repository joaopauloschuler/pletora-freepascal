{ %OPT=-O4 -OoPURE }
{ -OoPURE loop-pass fence relaxation for -OoREASSOC. A reduction addend
    acc := acc + f(a[i])
  where f is proven CONST or PURE by -OoPURE is side-effect free and
  non-trapping, so the pass may duplicate it with a shifted counter into four
  partial accumulators. PURE (global-reading) is admissible here because the
  reduction body's ONLY store is to the non-address-taken local accumulator, so
  nothing in the loop writes memory a pure callee could read.

  Correctness must hold regardless of whether the split fires: an integer sum is
  exact under any grouping. The reference kernels take the address of their
  accumulator, which makes -OoREASSOC decline them, so they stay a strictly
  serial reduction -- proving the split loop reproduces the serial result.
  A const-call, a pure-call and an FMA-of-const-call addend are each exercised.
  Halt(nonzero)=failure. }
program reassoc_purecall_01;
{$mode objfpc}{$H+}

var gfactor: longint = 3;   { read by the PURE helper, never written in a loop }

{ CONST: result depends only on its by-value parameter }
function sq(x: longint): longint; noinline;
begin sq := x*x; end;

{ PURE: reads a global but writes nothing }
function scaled(x: longint): longint; noinline;
begin scaled := x*gfactor + 1; end;

function sum_const_fast(const a: array of longint): longint;
var i,s: longint;
begin s:=0; for i:=0 to high(a) do s:=s+sq(a[i]); sum_const_fast:=s; end;

function sum_pure_fast(const a: array of longint): longint;
var i,s: longint;
begin s:=0; for i:=0 to high(a) do s:=s+scaled(a[i]); sum_pure_fast:=s; end;

{ mixed: a const call plus an array element in the same addend }
function sum_mixed_fast(const a: array of longint): longint;
var i,s: longint;
begin s:=0; for i:=0 to high(a) do s:=s+(sq(a[i])+a[i]); sum_mixed_fast:=s; end;

{ address-taken accumulator -> reassoc declines -> strictly sequential reference }
function sum_const_ref(const a: array of longint): longint;
var i,s: longint; p: pointer;
begin s:=0; p:=@s; for i:=0 to high(a) do s:=s+sq(a[i]); sum_const_ref:=s; if p=nil then Halt(9); end;

function sum_pure_ref(const a: array of longint): longint;
var i,s: longint; p: pointer;
begin s:=0; p:=@s; for i:=0 to high(a) do s:=s+scaled(a[i]); sum_pure_ref:=s; if p=nil then Halt(9); end;

function sum_mixed_ref(const a: array of longint): longint;
var i,s: longint; p: pointer;
begin s:=0; p:=@s; for i:=0 to high(a) do s:=s+(sq(a[i])+a[i]); sum_mixed_ref:=s; if p=nil then Halt(9); end;

var a: array of longint; i,n: longint;
begin
  for n:=0 to 40 do
    begin
      SetLength(a,n);
      for i:=0 to n-1 do a[i]:=(i mod 11)-5;
      if sum_const_fast(a)<>sum_const_ref(a) then Halt(1);
      if sum_pure_fast(a)<>sum_pure_ref(a) then Halt(2);
      if sum_mixed_fast(a)<>sum_mixed_ref(a) then Halt(3);
    end;
  { larger sizes covering every hi-3 residue }
  for n:=997 to 1000 do
    begin
      SetLength(a,n);
      for i:=0 to n-1 do a[i]:=(i mod 101)-50;
      if sum_const_fast(a)<>sum_const_ref(a) then Halt(4);
      if sum_pure_fast(a)<>sum_pure_ref(a) then Halt(5);
      if sum_mixed_fast(a)<>sum_mixed_ref(a) then Halt(6);
    end;
end.
