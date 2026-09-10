#!/usr/bin/perl
# lg_picture_mode_tokens_agree decides whether the mode the operator selected
# and the mode the TV reports (or the mode PGenerator last wrote) name the same
# picture mode. Full Auto Cal's preflight guard stops an hour of calibration on
# its answer, so its edge cases are load-bearing:
#   - the selector token and the readback token are NOT equal strings on every
#     generation (a DV "dolbyVisionCinema" selection reads back "dolbyHdrCinema"),
#     so the comparison must go through the label map, not raw ==;
#   - an empty token (unknown / failed probe) is not evidence of disagreement;
#   - an unmapped token falls back to raw compare, which can produce a false
#     disagreement -- the fail-safe direction, asserted here so it stays that way.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More tests => 12;

# pgenerator-lg is a modulino (`&main() if(!caller())`), so loading it defines
# its subs without running the helper.
my $helper = "$Bin/../usr/sbin/pgenerator-lg";
ok(-f $helper, 'pgenerator-lg is present');
my $rc = do $helper;
ok(defined $rc, 'pgenerator-lg loads as a module') or diag("error: $@");
ok(defined &main::lg_picture_mode_tokens_agree, 'the predicate is defined');

# --- straightforward agreement / disagreement ---
is(lg_picture_mode_tokens_agree('cinema','cinema','sdr'), 1, 'identical tokens agree');
is(lg_picture_mode_tokens_agree('filmMaker','filmmaker','sdr'), 1,
   'case/label variants of the same mode agree (filmMaker == filmmaker)');
is(lg_picture_mode_tokens_agree('cinema','filmMaker','sdr'), 0,
   'genuinely different modes disagree (Cinema vs Filmmaker)');

# --- the DV aliasing the raw-string trap would get wrong ---
is(lg_picture_mode_tokens_agree('dolbyVisionCinema','dolbyHdrCinema','dv'), 1,
   'DV Cinema selection agrees with its dolbyHdrCinema readback');
is(lg_picture_mode_tokens_agree('dolbyVisionFilmMaker','dolbyHdrCinema','dv'), 1,
   'DV Filmmaker agrees with dolbyHdrCinema (pre-2022 DV modes map together)');

# --- empty is "unknown", never a disagreement (guard must fail open) ---
is(lg_picture_mode_tokens_agree('','cinema','sdr'), 1, 'empty wanted -> no disagreement');
is(lg_picture_mode_tokens_agree('cinema','','sdr'), 1, 'empty readback -> no disagreement');
is(lg_picture_mode_tokens_agree('',''), 1, 'both empty -> no disagreement');

# --- unmapped tokens fall back to raw compare: two different unknowns must
#     disagree (fail-safe: a spurious stop, never a silent wrong-mode run) ---
is(lg_picture_mode_tokens_agree('someFutureModeA','someFutureModeB','sdr'), 0,
   'two distinct unmapped tokens disagree via raw fallback');
