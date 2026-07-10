#!/usr/bin/env bash
# Minimal shell runner for the unleashed test suite.
#
# The bundled Lazarus `testtool` cannot be built with the fork compiler yet
# (it needs fcl-process), so this script reproduces its verdict rules well
# enough to diff a baseline compiler against a self-hosted one.
#
# It walks testfiles/, extracts the first `{ ... }` comment (skipping
# `{$...}` directives), parses the %OPT / %FAIL / %NORUN / %TIMEOUT /
# %CHECKBIN_HAS / %CHECKBIN_LACKS directives, compiles each test with the
# given compiler, and (unless %NORUN / %FAIL) runs the produced binary under
# `ulimit -v` + `timeout`.  A PASS/FAIL line is printed per test and a sorted
# FAIL list is written to the log file.
#
# Usage: run_suite.sh [--cc PATH] [--log FILE] [--filter SUBSTR] [--jobs N]
#   --cc     compiler binary (default: ../../compiler/ppcx64)
#   --log    fail-list output (default: /tmp/unleashed_fail.log)
#   --filter only run tests whose path contains SUBSTR
#   --jobs   parallel workers (default: 8)
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="$root/compiler/ppcx64"
RTL="$root/rtl/units/x86_64-linux"
LOG="/tmp/unleashed_fail.log"
FILTER=""
JOBS=8

while [ $# -gt 0 ]; do
  case "$1" in
    --cc) CC="$2"; shift 2;;
    --log) LOG="$2"; shift 2;;
    --filter) FILTER="$2"; shift 2;;
    --jobs) JOBS="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[ -x "$CC" ] || { echo "compiler not executable: $CC" >&2; exit 2; }
[ -d "$RTL" ] || { echo "rtl unit dir missing: $RTL" >&2; exit 2; }

RESDIR="$(mktemp -d)"
trap 'rm -rf "$RESDIR"' EXIT

# Per-test worker. Emits one line: "PASS <rel>" or "FAIL <rel> <detail>".
run_one() {
  local f="$1"
  local rel="${f#$here/testfiles/}"
  local dir; dir="$(mktemp -d)"
  # Parse directives from the first non-{$...} { ... } comment.
  eval "$(perl "$here/parse_directives.pl" "$f")"
  local D_OPT="${D_OPT:-}" D_FAIL="${D_FAIL:-0}" D_NORUN="${D_NORUN:-0}"
  local D_TIMEOUT="${D_TIMEOUT:-0}" D_HAS="${D_HAS:-}" D_LACKS="${D_LACKS:-}"
  [ "$D_TIMEOUT" = "0" ] && D_TIMEOUT=30

  local checkbin=""
  [ -n "$D_HAS$D_LACKS" ] && checkbin="-Xs -XX -CX"
  local exe="$dir/t"
  # Compile.
  local cout
  cout="$( (ulimit -v 3000000; timeout 120 "$CC" -Fu"$RTL" -FU"$dir" -o"$exe" $D_OPT $checkbin "$f") 2>&1 )"
  local crc=$?

  if [ "$D_FAIL" = "1" ]; then
    if [ $crc -ne 0 ]; then echo "PASS $rel"; else echo "FAIL $rel expected-fail-but-compiled"; fi
    rm -rf "$dir"; return
  fi
  if [ $crc -ne 0 ]; then
    echo "FAIL $rel compile rc=$crc"
    rm -rf "$dir"; return
  fi
  # checkbin
  if [ -n "$D_HAS" ]; then
    local IFS=','; for s in $D_HAS; do
      grep -qF -- "$s" "$exe" || { echo "FAIL $rel checkbin-missing:$s"; rm -rf "$dir"; return; }
    done; unset IFS
  fi
  if [ -n "$D_LACKS" ]; then
    local IFS=','; for s in $D_LACKS; do
      grep -qF -- "$s" "$exe" && { echo "FAIL $rel checkbin-present:$s"; rm -rf "$dir"; return; }
    done; unset IFS
  fi
  if [ "$D_NORUN" = "1" ]; then echo "PASS $rel"; rm -rf "$dir"; return; fi
  # Run.
  ( ulimit -v 3000000; timeout "$D_TIMEOUT" "$exe" >/dev/null 2>&1 )
  local rrc=$?
  if [ $rrc -eq 0 ]; then echo "PASS $rel"; else echo "FAIL $rel run rc=$rrc"; fi
  rm -rf "$dir"
}
export -f run_one
export CC RTL here

mapfile -t FILES < <(find "$here/testfiles" \( -name '*.pp' -o -name '*.pas' \) | sort)
if [ -n "$FILTER" ]; then
  FILES=( $(printf '%s\n' "${FILES[@]}" | grep -F "$FILTER") )
fi

printf '%s\n' "${FILES[@]}" | xargs -P "$JOBS" -I{} bash -c 'run_one "$@"' _ {} > "$RESDIR/out" 2>/dev/null

total=$(wc -l < "$RESDIR/out")
grep -c '^PASS ' "$RESDIR/out" > "$RESDIR/np" || true
np=$(cat "$RESDIR/np")
grep '^FAIL ' "$RESDIR/out" | sort > "$LOG" || true
nf=$(wc -l < "$LOG")
echo "compiler: $CC"
echo "total=$total pass=$np fail=$nf"
echo "fail list -> $LOG"
