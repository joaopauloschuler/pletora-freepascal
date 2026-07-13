{ fft.bench — forward FFT of a fixed complex vector repeatedly.

  A pf-bench benchmark (see deflate.bench for the convention). Workload: an
  iterative radix-2 FFT of a deterministic length-8192 complex signal, REPS
  times; the checksum folds the rounded magnitudes of the transform with
  FNV-1a (identical every rep, so PF_BENCH_SCALE only changes the repeat
  count). The butterflies are a floating-point / trig hot loop — a classic
  vectorization and loop-optimization target.

  Self-contained on purpose (no library FFT): the kernel itself is the
  workload under test. Sized so one run is ~0.2–2 s at -O2, scale 1. }
program fft_bench;

{$mode objfpc}{$H+}

uses
  SysUtils, Math;

const
  N = 8192;         { power of two }
  BASE_REPS = 180;

type
  TComplex = record
    Re, Im: Double;
  end;
  TComplexArray = array of TComplex;

function BuildSignal: TComplexArray;
var
  i: Integer;
begin
  SetLength(Result, N);
  for i := 0 to N - 1 do
  begin
    Result[i].Re := Sin(i * 0.013) + 0.5 * Cos(i * 0.071);
    Result[i].Im := 0.25 * Sin(i * 0.005);
  end;
end;

{ Iterative in-place radix-2 Cooley–Tukey, bit-reversal permutation first. }
procedure Fft(var A: TComplexArray);
var
  i, j, bit, len, half, k: Integer;
  ang: Double;
  w, wl, u, v: TComplex;
begin
  j := 0;
  for i := 1 to N - 1 do
  begin
    bit := N shr 1;
    while (j and bit) <> 0 do
    begin
      j := j xor bit;
      bit := bit shr 1;
    end;
    j := j or bit;
    if i < j then
    begin
      u := A[i]; A[i] := A[j]; A[j] := u;
    end;
  end;
  len := 2;
  while len <= N do
  begin
    half := len shr 1;
    ang := -2.0 * Pi / len;
    wl.Re := Cos(ang);
    wl.Im := Sin(ang);
    i := 0;
    while i < N do
    begin
      w.Re := 1.0;
      w.Im := 0.0;
      for k := 0 to half - 1 do
      begin
        u := A[i + k];
        v.Re := A[i + k + half].Re * w.Re - A[i + k + half].Im * w.Im;
        v.Im := A[i + k + half].Re * w.Im + A[i + k + half].Im * w.Re;
        A[i + k].Re := u.Re + v.Re;
        A[i + k].Im := u.Im + v.Im;
        A[i + k + half].Re := u.Re - v.Re;
        A[i + k + half].Im := u.Im - v.Im;
        u.Re := w.Re * wl.Re - w.Im * wl.Im;
        u.Im := w.Re * wl.Im + w.Im * wl.Re;
        w := u;
      end;
      Inc(i, len);
    end;
    len := len shl 1;
  end;
end;

function Scale: Integer;
var
  s: string;
  v: Integer;
begin
  s := GetEnvironmentVariable('PF_BENCH_SCALE');
  if (s = '') or (not TryStrToInt(s, v)) or (v < 1) then
    v := 1;
  Result := v;
end;

var
  Sig, Spec: TComplexArray;
  i, r, reps: Integer;
  h, mag: QWord;
begin
  Sig := BuildSignal;
  reps := BASE_REPS div Scale;
  if reps < 1 then reps := 1;
  Spec := nil;
  for r := 1 to reps do
  begin
    Spec := Copy(Sig);
    Fft(Spec);
  end;
  { Fold the rounded magnitudes with FNV-1a so a miscompiled butterfly is
    caught. }
  h := QWord($CBF29CE484222325);
  for i := 0 to High(Spec) do
  begin
    mag := QWord(Round(Sqrt(Spec[i].Re * Spec[i].Re + Spec[i].Im * Spec[i].Im) * 1000));
    h := (h xor mag) * QWord($100000001B3);
  end;
  Writeln(Format('fft n=%d fnv=%.16x', [N, h]));
end.
