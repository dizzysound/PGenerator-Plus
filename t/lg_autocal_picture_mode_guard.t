#!/usr/bin/perl
# Structure guard for the Full Auto Cal picture-mode preflight in
# meterAutoCalRunPreflightReset (webui-workspace.js). That block decides
# whether to stop an hour of calibration, and its branch conditions are the
# load-bearing logic:
#   - a missing selection (!wanted) must stop BEFORE the readable/non-readable
#     split, so a readable set cannot start with no target (the asymmetry this
#     accompanies fixed);
#   - a readable set stops on a tv_picture_mode mismatch;
#   - a non-readable set stops on a last_written mismatch;
#   - a helper older than the probe (no picture_mode_readable field) is treated
#     as "cannot tell" and left alone.
#
# There is no JS execution harness in this repo (prove runs Perl), so this
# pins the branch STRUCTURE by source assertion -- the same idiom the existing
# JS-touching tests use. It catches a condition being inverted, dropped, or the
# !wanted check regressing back into a single branch.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More tests => 6;

my $js = "$Bin/../usr/share/PGenerator/webui-workspace.js";
ok(-f $js, 'webui-workspace.js is present');
open(my $fh,'<',$js) or die "read $js: $!";
local $/; my $src=<$fh>; close($fh);

# Isolate the preflight guard body so assertions cannot match lookalike code
# elsewhere in the file.
my ($guard) = $src =~ /(hasOwnProperty\.call\(ddcReset,'picture_mode_readable'\).*?meterAutoCalPreflightLgGeneration=)/s;
ok($guard, 'the preflight guard block is present');
$guard //= '';

like($guard, qr/if\(!wanted\)\{[^}]*throw/s,
     'a missing selection stops the run');
# The !wanted stop must precede the readable branch (shared by both paths).
ok(index($guard, 'if(!wanted)') >= 0
   && index($guard, 'if(!wanted)') < index($guard, 'if(ddcReset.picture_mode_readable)'),
   '!wanted is checked before the readable/non-readable split');
like($guard, qr/picture_mode_readable\)\{.*?!ddcReset\.tv_picture_mode_matches.*?throw/s,
     'readable branch stops on a tv_picture_mode mismatch');
like($guard, qr/!ddcReset\.last_written_picture_mode_matches.*?throw/s,
     'non-readable branch stops on a last_written mismatch');
