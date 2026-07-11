#!/usr/bin/env bash
# Precision checks for the -O4 nested-procedure-def DFA false-positive suppression
# (compiler/optdfa.pas CollectNestedProcDefSyms, wired in compiler/psub.pas).
#
# The DFA at -O3/-O4 spuriously reports a local of an enclosing routine "does not
# seem to be initialized" when it is assigned ONLY inside a nested procedure that
# the routine calls before reading the local (self-host blocker on
# compiler/x86/aoptx86.pas anchors/acount/anchor, via nested CollectAnchors/
# FindAnchor).  The DFA does not model a nested-procedure call as a definition of
# the captured parent local.  The fix suppresses that WARNING only for a parent
# local written by a nested routine that is actually called; it must NOT hide
# genuine uninitialized reads, and must not touch codegen.
#
# Part A: the false-positive shapes compile clean at -O4 -Sew (warning would be
#         a fatal error) and run correctly.
# Part B: genuine uninitialized reads STILL warn (guard against over-suppression):
#         a local no nested routine writes, and a local written only by a nested
#         routine that is NEVER called.
#
# Usage: unleashed/tests/nestedprocdef_dfa_check.sh [path-to-ppcx64]
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CC="${1:-$root/compiler/ppcx64}"
RTL="$root/rtl/units/x86_64-linux"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

rc=0
fail() { echo "FAIL: $*"; rc=1; }

# compile $1 at flags $2 ; echo the "not initialized" note lines (may be empty)
notes() {
  ( ulimit -v 3000000; timeout 60 "$CC" -Fu"$RTL" $2 -o"$tmp/e" "$1" ) 2>&1 \
    | grep -iE 'does not seem to be initialized'
}

# ---------------------------------------------------------------------------
# Part A: nested-proc-def shapes must be silent (and compile + run) at -O4.
# ---------------------------------------------------------------------------

# A1: managed (class) and scalar locals defined only inside a nested procedure.
cat > "$tmp/good1.pp" <<'EOF'
{$mode objfpc}
type tobj = class end;
function build(n : integer) : integer;
var anchor : tobj; cnt : integer;
  procedure findanchor;
  begin
    anchor := nil; cnt := 0;
    if n > 1 then begin anchor := tobj.create; cnt := n; end;
  end;
begin
  findanchor;
  if not assigned(anchor) then exit(0);
  build := cnt;
  anchor.free;
end;
begin
  if build(3)<>3 then begin writeln('FAIL n>1'); halt(1); end;
  if build(1)<>0 then begin writeln('FAIL n<=1'); halt(1); end;
  writeln('ok');
end.
EOF

# A2: nested-of-nested writes a grandparent local, reached through the caller.
cat > "$tmp/good2.pp" <<'EOF'
{$mode objfpc}
function build2(n : integer) : integer;
var total : integer;
  procedure outer;
    procedure inner; begin total := n * 2; end;
  begin inner; end;
begin
  outer;
  build2 := total;
end;
begin
  if build2(5)<>10 then begin writeln('FAIL'); halt(1); end;
  writeln('ok');
end.
EOF

for g in good1 good2; do
  n="$(notes "$tmp/$g.pp" "-O4 -Sew")"
  if [ -n "$n" ]; then fail "$g: nested-proc-def shape still warns at -O4:"; echo "$n"; fi
  if [ -x "$tmp/e" ]; then
    out="$( ulimit -v 3000000; timeout 30 "$tmp/e" )"
    [ "$out" = "ok" ] || fail "$g: wrong runtime result: '$out'"
  else
    fail "$g: did not compile at -O4 -Sew"
  fi
done

# ---------------------------------------------------------------------------
# Part B: genuine uninitialized reads must STILL warn (no over-suppression).
# ---------------------------------------------------------------------------

# B1: local never written by any nested routine.
cat > "$tmp/bad1.pp" <<'EOF'
{$mode objfpc}
function f(n : integer) : integer;
var x : integer;
  procedure noop; begin end;
begin noop; f := x; end;
begin writeln(f(3)); end.
EOF

# B2: local written only by a nested routine that is NEVER called.
cat > "$tmp/bad2.pp" <<'EOF'
{$mode objfpc}
function f(n : integer) : integer;
var x : integer;
  procedure setit; begin x := n; end;
begin f := x; end;
begin writeln(f(3)); end.
EOF

for b in bad1 bad2; do
  n="$(notes "$tmp/$b.pp" "-O4")"
  [ -n "$n" ] || fail "$b: genuine uninitialized read no longer warns (over-suppressed)"
done

[ "$rc" -eq 0 ] && echo "PASS: nested-proc-def silent at -O4; genuine uninitialized reads still warn"
exit "$rc"
