# pf-bench

A benchmark harness for the FPC Unleashed optimizer work. It discovers
`bench/*.bench.lpr` programs (this repo ships a fixture set in
[`unleashed/tests/bench/`](../../tests/bench/)), builds each with a
**selectable compiler and flag set**, and runs them with warm-up and repeated
timed runs **under a memory + time cap**.

Every benchmark prints a **single deterministic checksum line**, so pf-bench
can assert two builds produced the *same answer* before comparing their speed —
an optimizer pass that miscompiles must **fail the run, not win it**.

Ported into this repository from the fantastica monorepo's pf-bench; the
fantastica `core.*`/`timeit` dependencies were replaced with FCL/RTL
equivalents (`fcl-process` TProcess, `csvdocument`, `clock_gettime`, `Math`).

## Build

```sh
unleashed/tools/pf-bench/build.sh        # → bin/pf-bench
```

Precondition: the in-tree compiler, RTL and packages are built
(`./rebuildu.sh` from the repo root). The engine uses `fcl-process` and
`fcl-base`; the shipped fixtures additionally use `paszlib`, `regexpr` and
`fcl-hash`.

## Modes

### Baseline / regression gate

```sh
pf-bench run --save baseline.csv                  # record per-benchmark medians
pf-bench run --against baseline.csv --threshold 5 # compare; regress past 5% = exit 1
```

`--save` writes a CSV of per-benchmark medians (and the checksum). `--against`
re-runs, computes each benchmark's median delta versus the baseline, and
**exits non-zero if any benchmark is slower than the baseline by more than
`--threshold` percent** — so CI can gate on it. A benchmark absent from the
baseline is reported as new and never counts as a regression.

### A/B compiler comparison

```sh
pf-bench ab --compiler-a fpc --compiler-b ./fpcu.sh --flags=-O2
```

Builds every benchmark **twice** (once per compiler), then **interleaves the
timed runs ABAB…** — on each scored iteration it runs A then B — so any thermal
or CPU-frequency drift over the run falls on both compilers equally. It prints
a per-benchmark speedup table (`A median / B median`; `>1` means B is faster).
Before trusting any speed number it checks that A and B produced the **same
checksum**; a mismatch marks the row void and fails the run.

## CLI

```
pf-bench run [--compiler NAME|PATH] [--save FILE] [--against FILE [--threshold PCT]] [common]
pf-bench ab  --compiler-a NAME|PATH --compiler-b NAME|PATH [--flags-a=…] [--flags-b=…] [common]

common: --root DIR --filter SUBSTR --runs N --warmup N --timeout SECS --flags=… --verbose
```

- `--root DIR` — benchmark tree root (default: `<repo>/unleashed/tests`,
  resolved from the executable's location). Discovery scans `DIR/bench`,
  `DIR/*/bench` and `DIR/*/*/bench`, so pointing `--root` at a monorepo
  checkout still sweeps `<loc>/<proj>/bench/` layouts.
- `--filter SUBSTR` — only benchmarks whose `<project>/<name>` contains `SUBSTR`.
- `--runs N` — timed runs per benchmark (default 8); `--warmup N` discarded
  warm-ups (default 1).
- `--timeout SECS` — per-run wall-clock cap (default 120); each run also gets
  `ulimit -v 3000000` (~3 GB) applied via `bash` before exec.
- `--flags=…` — extra compiler flags (whitespace-separated), appended verbatim
  after the project's own `-Fu<proj>/src` (if it has one). The default
  compiler is the repo's `fpcu.sh` wrapper, which supplies the RTL + packages
  unit paths; a bare compiler path needs those passed via `--flags`. In `ab`
  mode, `--flags-a=…` / `--flags-b=…` add per-side flags.

> **Value flags starting with `-` must use the `=` form** (`--flags=-O2`, not
> `--flags -O2`): the parser will not consume a following token that itself
> begins with `-`.

Environment:

- `PF_BENCH_CPU=<cpulist>` — pin every timed run to the given CPU(s) via
  `taskset -c`. On hybrid P/E-core machines an unpinned run lands on either
  core type and timings swing by ~2x; pin (e.g. `PF_BENCH_CPU=0`) for stable
  medians.
- `PF_BENCH_SCALE=N` — honored by the fixtures themselves: divides their
  repeat count for a fast smoke run **without changing the checksum**.

Exit codes: `0` = success; `1` = usage/IO error, a build/run failure, a
checksum mismatch, or (with `--against`) a regression past the threshold.

## Writing a benchmark

Drop a `bench/<name>.bench.lpr` into the fixture tree. It must be a
**self-timing-free plain program** that runs a **fixed deterministic
workload**, exits `0`, and prints **one checksum line** (pf-bench reads the
last non-empty stdout line):

```pascal
program fft_bench;
{$mode objfpc}{$H+}
uses SysUtils, Math;
// … build a fixed input, transform it BASE_REPS times, fold the result …
begin
  Writeln(Format('fft n=%d fnv=%.16x', [N, h]));
end.
```

Size each workload so **one run is roughly 0.2–2 s** at the optimization level
you will benchmark (e.g. `-O2`), and honor `PF_BENCH_SCALE`
(`BASE_REPS div scale`, clamped to ≥1) so smoke runs stay cheap.

Shipped fixtures (`unleashed/tests/bench/`): `deflate` (paszlib), `sha256`
(fcl-hash), `regex` (regexpr TRegExpr), `fft` and `matrix` (self-contained
kernels) — real branchy library code plus the classic float hot loops.

## Layout

```
pf-bench/
├── README.md
├── build.sh                 # build bin/pf-bench with the in-tree compiler
├── build-tests.sh           # build + run the engine tests
├── src/
│   └── pfbench.engine.pas   # discovery + stats + baseline/AB + build/run
├── proj/
│   └── pf-bench.lpr         # thin CLI (run / ab) over pfbench.engine
├── bin/                     # compiled binary (git-ignored)
└── tests/
    └── pfbench.tests.lpr    # assert-style engine tests + one guarded e2e
```

The logic lives in `src/pfbench.engine.pas` so every pure half — discovery,
median, checksum extraction, baseline CSV + compare, A/B aggregation — is
unit-testable without invoking a compiler; the build/run helpers wrap
TProcess under the cap.

## Used by

[`unleashed/tests/o4_pass_speedup_bench.sh`](../../tests/o4_pass_speedup_bench.sh)
— the leave-one-in speedup matrix over the -O4 default optimizer passes.
