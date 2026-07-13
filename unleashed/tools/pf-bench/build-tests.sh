#!/usr/bin/env bash
# Build and run the pf-bench engine tests with the in-tree compiler.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
tmp="$here/tests/bin_tmp"
mkdir -p "$tmp"
"$root/fpcu.sh" -O2 -Fu"$here/src" -FU"$tmp" -o"$here/tests/pfbenchtests" \
    "$here/tests/pfbench.tests.lpr"
rm -rf "$tmp"
"$here/tests/pfbenchtests"
