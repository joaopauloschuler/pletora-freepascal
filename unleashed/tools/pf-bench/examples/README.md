# pf-bench — examples

Runnable walkthroughs for the `pf-bench` benchmark harness. Build the binary
first (from the project root):

```sh
cd ../proj
mkdir -p bin_tmp
fpc -Fu../src -Fu../../core/src -Fu../../timeit/src -Fl../../core/csrc \
    -FUbin_tmp -o../bin/pf-bench pf-bench.lpr
rm -rf bin_tmp
cd ..
```

The binary is then at `bin/pf-bench`. Run everything under the standard guard:

```sh
ulimit -v 3000000
```

Paths below assume you run from `fantastica/pf-bench/`. Remember: **value flags
whose value starts with `-` need the `=` form** (`--flags=-O2`).

## 1. List / time every benchmark

```sh
$ bin/pf-bench run --flags=-O2 --runs 5
[INFO] run: 5 benchmark(s), compiler=/usr/bin/fpc, runs=5 warmup=1
[INFO]   core/blake3   median 234ms…  mean …  min …  cksum blake3 ab80ff47…
[INFO]   core/deflate  median 1s271ms…  …  cksum deflate len=123352 crc=F6E38A93
[INFO]   core/fft      median 508ms…  …  cksum fft n=8192 crc=9542C975
[INFO]   core/matrix   median 1s93ms…  …  cksum matrix dim=96 crc=3798A60E
[INFO]   grep/grep     median …  …  cksum grep pattern=server=[a-z]+[0-9]+ matches=6000 lines=6000
```

`--filter SUBSTR` narrows to matching benchmarks (`--filter core/fft`).
Each benchmark prints the checksum pf-bench uses to prove correctness.

## 2. Record a baseline, then gate on regressions

```sh
$ bin/pf-bench run --flags=-O2 --filter core/fft --save baseline.csv
[INFO]   core/fft   median 523ms952us952ns  …  cksum fft n=8192 crc=9542C975
[INFO] saved baseline to baseline.csv

$ cat baseline.csv
name,median_ns,mean_ns,checksum
core/fft,523952952,533441910,fft n=8192 crc=9542C975

$ bin/pf-bench run --flags=-O2 --filter core/fft --against baseline.csv --threshold 25
[INFO] compare vs baseline.csv (threshold 25.00%):
[INFO]   core/fft   +8.14%  (523ms952us952ns -> 566ms599us128ns)
[INFO] OK: no benchmark regressed past the threshold
$ echo $?
0
```

A result slower than the baseline by more than `--threshold` percent flags a
`REGRESSION` and exits non-zero, so CI can gate:

```sh
$ bin/pf-bench run --flags=-O2 --filter core/fft --against baseline.csv --threshold 1
[ERROR]   core/fft   +8.14%  REGRESSION  (523ms952us952ns -> 566ms599us128ns)
[ERROR] FAIL: one or more benchmarks regressed past the threshold
$ echo $?
1
```

## 3. A/B: system `fpc` vs the fork compiler

Build every benchmark twice and interleave the timed runs (ABAB…). The fork
compiler needs its RTL units on the unit path, passed as a `-Fu` in `--flags-b`:

```sh
$ FORK=../../pletora/freepascal/compiler/ppcx64
$ RTL=../../pletora/freepascal/rtl/units/x86_64-linux
$ bin/pf-bench ab --filter core/ \
      --compiler-a fpc --compiler-b "$FORK" \
      --flags=-O2 --flags-b=-Fu"$RTL" --runs 5 --warmup 1

benchmark                      A median       B median   speedup  status
------------------------------------------------------------------------------
core/blake3              467ms322us17ns 234ms656us412ns    1.992x  ok
core/deflate             1s240ms986us246ns 1s271ms257us477ns    0.976x  ok
core/fft                 508ms20us889ns 826ms825us499ns    0.614x  ok
core/matrix              1s93ms206us246ns 1s147ms974us385ns    0.952x  ok
------------------------------------------------------------------------------
speedup = A median / B median  (>1 means B is faster)
```

`status` is `ok` only when A and B produced the **same checksum** and neither
side had a failed run. A checksum mismatch (a miscompiling optimizer pass) marks
the row `CHECKSUM MISMATCH …` and makes pf-bench exit non-zero — the wrong answer
can never win on speed.

## 4. Fast smoke via PF_BENCH_SCALE

Benchmarks divide their repeat count by `PF_BENCH_SCALE` (default 1) **without
changing the checksum**, so you can shrink a run for a quick check:

```sh
$ PF_BENCH_SCALE=8 bin/pf-bench run --flags=-O2 --filter core/matrix --runs 3
```

## 5. Help

```sh
$ bin/pf-bench --help
```
