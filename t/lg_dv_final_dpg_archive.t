#!/usr/bin/perl
# Regression tests for the Dolby Vision Calibration History gap.
#
# A full workflow defers the post-calibration low-end smoothing and its
# Calibration History archive to the 3D stage. Dolby Vision has no 3D stage
# (lg_generation_profile returns a constant dv_mode => "1d_only"), so a DV full
# workflow deferred the work to a stage that never ran: the curve was never
# smoothed and never durably archived, leaving only the transient
# run-directory entry that autocal-runs rotation or a reflash destroys.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More tests => 37;

# The worker guards its main block with `unless(caller())`, so loading it here
# defines its subs without running a calibration.
my $worker = "$Bin/../usr/bin/meter_lg_autocal.pl";
ok(-f $worker, 'meter_lg_autocal.pl is present');
my $rc = do $worker;
ok(defined $rc, 'worker loads without running main') or diag("error: $@");

ok(defined &main::autocal_defers_final_dpg_archive, 'deferral predicate is defined');
ok(defined &main::autocal_hdr20_archive_signal_mode, 'archive-label helper is defined');
ok(defined &main::autocal_applies_low_end_smoothing, 'smoothing predicate is defined');

# --- when the greyscale worker must defer to the 3D stage ---
is(autocal_defers_final_dpg_archive({ full_workflow => 1, signal_mode => 'sdr' }), 1,
   'SDR full workflow defers (its 3D stage rewrites the DPG)');
is(autocal_defers_final_dpg_archive({ full_workflow => 1, signal_mode => 'hdr10' }), 1,
   'HDR10 full workflow defers (tone-map and shadow fix rewrite the DPG)');
is(autocal_defers_final_dpg_archive({ full_workflow => 1 }), 1,
   'full workflow with no signal_mode defers (defaults to the SDR ladder)');

# --- when it must not defer ---
is(autocal_defers_final_dpg_archive({ full_workflow => 1, signal_mode => 'dv' }), 0,
   'DV full workflow does NOT defer -- no 3D stage would ever archive it');
is(autocal_defers_final_dpg_archive({ full_workflow => 1, signal_mode => 'DV' }), 0,
   'DV detection is case-insensitive');
is(autocal_defers_final_dpg_archive({ full_workflow => 0, signal_mode => 'hdr10' }), 0,
   'standalone HDR10 run smooths and archives in place');
is(autocal_defers_final_dpg_archive({ signal_mode => 'sdr' }), 0,
   'a run with no full_workflow flag smooths and archives in place');
is(autocal_defers_final_dpg_archive(undef), 0, 'undef config never defers');

# --- Calibration History label ---
is(autocal_hdr20_archive_signal_mode({ signal_mode => 'dv' }), 'dv',
   'a DV curve is filed under signal mode dv');
is(autocal_hdr20_archive_signal_mode({ signal_mode => 'hdr10' }), 'hdr10',
   'an HDR10 curve is still filed under hdr10');
is(autocal_hdr20_archive_signal_mode({}), 'hdr10',
   'the HDR20 path defaults to hdr10 when the mode is unknown');

# --- the behavioural regression, stated against the old guard ---
#
# Before the fix the call sites tested `!$config->{"full_workflow"}` directly.
# The predicate must agree with that naive test everywhere EXCEPT a Dolby
# Vision full workflow, which is precisely the case that lost its curve.
my @matrix = (
    { full_workflow => 0, signal_mode => 'sdr'   },
    { full_workflow => 0, signal_mode => 'hdr10' },
    { full_workflow => 0, signal_mode => 'dv'    },
    { full_workflow => 1, signal_mode => 'sdr'   },
    { full_workflow => 1, signal_mode => 'hdr10' },
    { full_workflow => 1, signal_mode => 'dv'    },
);
my @diverged;
for my $cfg (@matrix) {
    my $old = $cfg->{full_workflow} ? 1 : 0;              # the guard as it was
    my $new = autocal_defers_final_dpg_archive($cfg);
    push @diverged, $cfg->{signal_mode} if $old != $new;
}
is(scalar(@diverged), 1, 'the fix changes exactly one case in the matrix');
is($diverged[0], 'dv', 'and that case is Dolby Vision');

# A DV full workflow is the only configuration where deferring means the
# archive never happens at all, because no 3D stage follows it.
ok(!autocal_defers_final_dpg_archive({ full_workflow => 1, signal_mode => 'dv' }),
   'DV full workflow archives in the greyscale worker');
ok(autocal_defers_final_dpg_archive({ full_workflow => 1, signal_mode => 'hdr10' }),
   'HDR10 full workflow still leaves the archive to the 3D stage');

# --- low-end smoothing must not be applied to Dolby Vision ---
#
# SDR and HDR10 have always received the post-calibration low-end smoothing.
# Dolby Vision never did, because the block was unreachable for DV, and it
# must stay that way. Measured on an LG C1 with everything else held equal --
# Dark Detail on, 37 anchors, 8-bit, same meter -- routing DV through
# smooth_dpg_low_end moved post-calibration greyscale from mean dE ITP 0.995
# to 1.756 and the worst point from 1.92 to 5.37, concentrated between 5% and
# 35%, which is the range the smoothing rewrites. Luminance-compensated dE was
# unchanged (0.808 vs 0.797), so the cost is luminance accuracy.
is(autocal_applies_low_end_smoothing({ signal_mode => 'sdr' }), 1,
   'SDR still gets low-end smoothing');
is(autocal_applies_low_end_smoothing({ signal_mode => 'hdr10' }), 1,
   'HDR10 still gets low-end smoothing');
is(autocal_applies_low_end_smoothing({ signal_mode => 'dv' }), 0,
   'Dolby Vision does NOT get low-end smoothing');
is(autocal_applies_low_end_smoothing({ signal_mode => 'DV' }), 0,
   'smoothing opt-out is case-insensitive');
is(autocal_applies_low_end_smoothing({}), 1,
   'an unknown signal mode keeps the existing smoothing behaviour');
is(autocal_applies_low_end_smoothing(undef), 1,
   'undef config keeps the existing smoothing behaviour');

# --- the two predicates together describe the intended DV behaviour ---
my $dv = { full_workflow => 1, signal_mode => 'dv' };
ok(!autocal_defers_final_dpg_archive($dv), 'DV archives in the greyscale worker');
ok(!autocal_applies_low_end_smoothing($dv), 'and archives the committed curve, unsmoothed');

my $hdr = { full_workflow => 1, signal_mode => 'hdr10' };
ok(autocal_defers_final_dpg_archive($hdr), 'HDR10 full workflow still defers to the 3D stage');
ok(autocal_applies_low_end_smoothing($hdr), 'and HDR10 smoothing behaviour is untouched');

# --- the archive-only branch's payload, pinned by source (no JS/TV in CI) ---
#
# The predicates above decide WHETHER to archive; these pin WHAT the DV archive
# branch sends. That branch is the only path a DV curve has into Calibration
# History, so a regression dropping archive_history, mislabelling the signal
# mode, or adding a "smoothed" variant would silently reintroduce the bug or
# misfile the entry. No hardware runs in CI, so assert the source.
my $worker_src;
{
 local $/;
 open(my $wfh,'<',"$Bin/../usr/bin/meter_lg_autocal.pl") or die "read worker: $!";
 $worker_src=<$wfh>;
 close($wfh);
}
my ($dv_branch) = $worker_src =~ /if\(!\$apply_smoothing\)\s*\{(.*?)my \(\$smoothed,\$changed\)=/s;
ok($dv_branch, 'the DV archive-only branch is present');
$dv_branch //= '';
like($dv_branch, qr/archive_history=>JSON::PP::true/,
     'DV branch archives (archive_history true)');
like($dv_branch, qr/signal_mode=>autocal_hdr20_archive_signal_mode\(\$config\)/,
     'DV branch labels the entry from the run, not a hardcoded mode');
like($dv_branch, qr/archive_run_id=>/,
     'DV branch carries the run id for the history entry');
unlike($dv_branch, qr/archive_variant/,
       'DV branch archives the committed curve, not a "smoothed" variant');

# The closure merges its own defaults with the caller's %{$extra}. In a Perl
# hash literal the LAST key wins, so the closure's signal_mode default must
# sit BEFORE %{$extra} -- otherwise it silently outranks the archive label
# from autocal_hdr20_archive_signal_mode() and the entry is filed from the
# closure's copy instead of the run's (the review finding on PR 2).
my ($hdr20_closure) = $worker_src =~ /my \(\$dpg,\$extra\)=\@_;.*?upload\",\{(.*?)\n\s*\},120\);/s;
ok($hdr20_closure, 'captured the hdr20 upload closure body');
my $closure = $hdr20_closure // '';
my $default_at = index($closure, 'signal_mode=>$config->{"signal_mode"}');
my $extra_at   = index($closure, '%{$extra},');
ok($default_at >= 0 && $extra_at >= 0 && $default_at < $extra_at,
   'closure signal_mode default precedes %{$extra} so the caller label wins');
