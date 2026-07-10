#!/usr/bin/perl
# Parse unleashed test directives from the first `{ ... }` comment that is not
# a `{$...}` compiler directive.  Emits shell-eval-able KEY=VALUE lines.
use strict; use warnings;
local $/; my $src = <>;
sub shq { my $s = shift; $s =~ s/'/'\\''/g; return "'$s'"; }
my ($opt,$fail,$norun,$to,$has,$lacks) = ("",0,0,0,"","");
while ($src =~ /\{([^\$].*?)\}/sg) {
  my $c = $1;
  next unless $c =~ /%/;
  if    ($c =~ /%OPT="([^"]*)"/) { $opt = $1; }
  elsif ($c =~ /%OPT=(\S+)/)     { $opt = $1; }
  $fail  = 1  if $c =~ /%FAIL\b/i;
  $norun = 1  if $c =~ /%NORUN\b/i;
  $to    = $1 if $c =~ /%TIMEOUT=(\d+)/i;
  if    ($c =~ /%CHECKBIN_HAS="([^"]*)"/) { $has = $1; }
  elsif ($c =~ /%CHECKBIN_HAS=(\S+)/)     { $has = $1; }
  if    ($c =~ /%CHECKBIN_LACKS="([^"]*)"/) { $lacks = $1; }
  elsif ($c =~ /%CHECKBIN_LACKS=(\S+)/)     { $lacks = $1; }
  last;
}
print "D_OPT=",   shq($opt),   "\n";
print "D_FAIL=$fail\n";
print "D_NORUN=$norun\n";
print "D_TIMEOUT=$to\n";
print "D_HAS=",   shq($has),   "\n";
print "D_LACKS=", shq($lacks), "\n";
