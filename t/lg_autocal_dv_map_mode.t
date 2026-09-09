#!/usr/bin/perl
# A Dolby Vision AutoCal must calibrate in Relative map mode.
#
# lg_autocal_expected_gamma_for_signal_mode_and_ire returns 2.2 for dv, so the
# solver always aims at a 2.2 curve. Only Relative presents that curve;
# Absolute presents ST 2084. The Web UI switches dv_map_mode to Relative
# before a DV run (meterDvAutoCalApplyMapMode in webui-workspace.js), but a
# caller driving POST /api/meter/lg-autocal directly has no such step, and the
# run completes and commits a curve solved against a target the panel was not
# showing. The guard turns that into an immediate, actionable error.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More tests => 14;

my $webui = "$Bin/../usr/share/PGenerator/webui.pm";
ok(-f $webui, 'webui.pm is present');

# webui.pm is a plain module: loading it defines its subs without starting a
# daemon. Its siblings must be on @INC.
unshift @INC, "$Bin/../usr/share/PGenerator";
my $rc = do $webui;
ok(defined $rc, 'webui.pm loads') or diag("error: $@");
ok(defined &main::webui_lg_autocal_dv_map_mode_error, 'the guard predicate is defined');

# --- Dolby Vision: Relative is the only accepted mode ---
is(webui_lg_autocal_dv_map_mode_error('dv','2'), '',
   'DV in Relative (2) is allowed');
isnt(webui_lg_autocal_dv_map_mode_error('dv','1'), '',
   'DV in Absolute (1) is refused');
like(webui_lg_autocal_dv_map_mode_error('dv','1'), qr/Absolute/,
   'the message names the mode actually set');
like(webui_lg_autocal_dv_map_mode_error('dv','1'), qr/Relative/,
   'and the mode the operator needs');
isnt(webui_lg_autocal_dv_map_mode_error('dv',''), '',
   'DV with no map mode configured is refused');
like(webui_lg_autocal_dv_map_mode_error('dv',undef), qr/unset/,
   'an undefined map mode reports as unset rather than dying');
isnt(webui_lg_autocal_dv_map_mode_error('dv','3'), '',
   'an unexpected map-mode value is refused rather than assumed safe');

# --- tolerant of the shapes a config value actually arrives in ---
is(webui_lg_autocal_dv_map_mode_error('dv',' 2 '), '',
   'surrounding whitespace does not turn a valid mode into a failure');
is(webui_lg_autocal_dv_map_mode_error('DV','2'), '',
   'signal mode match is case-insensitive');

# --- every other signal mode is none of this guard's business ---
is(webui_lg_autocal_dv_map_mode_error('hdr10','1'), '',
   'HDR10 is unaffected by the DV map mode');
is(webui_lg_autocal_dv_map_mode_error('sdr',''), '',
   'SDR is unaffected');
