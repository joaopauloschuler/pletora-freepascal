#!/bin/sh
# Wrapper for the in-tree FPC Unleashed compiler: resolves the built ppcx64
# and unit paths from the repo root so it works from any directory. It adds
# no optimization or debug flags of its own - pass -O4 for release builds to
# enable the fork's extra optimizer passes, or -g for debugging.
FP="$(cd "$(dirname "$0")" && pwd)"
# The RTL/package paths go AFTER the caller's arguments: unit paths are
# searched in the order given, and some FPC packages ship units whose names
# collide with project units (e.g. fv's menus.ppu vs the LCL's Menus), so
# the caller's -Fu paths must take precedence.
exec "$FP/compiler/ppcx64" \
  "$@" \
  "-Fu$FP/rtl/units/x86_64-linux" \
  "-Fu$FP/packages/*/units/x86_64-linux"
