#!/usr/bin/env bash
# Build pf-bench with the in-tree compiler via fpcu.sh (which supplies the
# RTL and packages/*/units unit paths). Precondition: the compiler, RTL and
# packages are built — from the repo root:
#
#   make compiler_cycle && make rtl packages FPC=$PWD/compiler/ppcx64
#   (or ./rebuildu.sh)
#
# pf-bench uses fcl-process, fcl-base, fcl-hash, paszlib and regexpr units.
# Usage: unleashed/tools/pf-bench/build.sh [extra fpc flags, e.g. -g]
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
tmp="$here/bin_tmp"
mkdir -p "$tmp" "$here/bin"
"$root/fpcu.sh" -O2 "$@" -Fu"$here/src" -FU"$tmp" -o"$here/bin/pf-bench" \
    "$here/proj/pf-bench.lpr"
rm -rf "$tmp"
echo "built: $here/bin/pf-bench"
