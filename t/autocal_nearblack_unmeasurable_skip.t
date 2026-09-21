#!/usr/bin/perl
# A deepest near-black SDR patch (e.g. sdr26_2.3% on an LG C1) can emit light
# below the colorimeter's usable floor: the meter returns no valid sample after
# the whole retry budget. Historically that unmeasurable read aborted the ENTIRE
# greyscale job (autocal_dpg_read_failure -> die), so a sweep that was otherwise
# complete committed nothing. This test pins the fix: such a patch is carried
# forward (left uncorrected / interpolated from neighbors) and the sweep
# finishes, while a mid/high patch that cannot be read STILL aborts -- that is a
# real meter/signal/alignment fault, not an expected sub-floor condition.
use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use Test::More;
use JSON::PP ();
do "$Bin/../usr/bin/meter_lg_autocal.pl"; die $@ if $@;
local *main::write_state=sub {};
local *main::log_line=sub {};

my $UNMEASURABLE="No usable meter measurement for sdr26_2.3% after 4 sample attempts; check the signal range, displayed patch and meter alignment";

# ---------------------------------------------------------------------------
# 1. The meter-floor helper: defaults, clamps and the independent SDR/HDR keys.
# ---------------------------------------------------------------------------
is(main::autocal_dpg_meter_floor({},"sdr"),0.003,'SDR meter floor defaults to 0.003');
is(main::autocal_dpg_meter_floor({},"hdr20"),0.003,'HDR meter floor defaults to 0.003');
is(main::autocal_dpg_meter_floor({lg_autocal_sdr26_dpg_meter_floor=>0.01},"sdr"),0.01,'SDR meter floor honours its own knob');
is(main::autocal_dpg_meter_floor({lg_autocal_sdr26_dpg_meter_floor=>0.01},"hdr20"),0.003,'the HDR floor ignores the SDR knob');
is(main::autocal_dpg_meter_floor({lg_autocal_sdr26_dpg_meter_floor=>9},"sdr"),0.05,'meter floor is clamped to a sane ceiling');
is(main::autocal_dpg_meter_floor({lg_autocal_sdr26_dpg_meter_floor=>0},"sdr"),0.0005,'meter floor is clamped to a sane floor');

# ---------------------------------------------------------------------------
# 2. The skip predicate: every guard must agree, so a real fault still aborts.
# ---------------------------------------------------------------------------
my $step_nb={name=>"sdr26_2.3%",ire=>2.3};
# All guards satisfied: deepest near-black, meter proven, sub-floor target,
# unmeasurable-sample class.
ok(main::autocal_nearblack_unmeasurable_skip({},"sdr",$step_nb,0.0117,$UNMEASURABLE,1),
   'skips a deepest near-black, sub-floor, unmeasurable patch once the meter is proven');
# Guard 1: meter not yet proven this pass.
ok(!main::autocal_nearblack_unmeasurable_skip({},"sdr",$step_nb,0.0117,$UNMEASURABLE,0),
   'never skips before any valid read has proven the meter');
# Guard 2: IRE above the deepest near-black cap.
ok(!main::autocal_nearblack_unmeasurable_skip({},"sdr",{name=>"5%",ire=>5},0.0117,$UNMEASURABLE,1),
   'never skips a mid/low patch above the near-black IRE cap');
# Guard 3: expected luminance well above the meter floor.
ok(!main::autocal_nearblack_unmeasurable_skip({},"sdr",$step_nb,0.05,$UNMEASURABLE,1),
   'never skips when the expected target sits above the meter floor margin');
# Guard 4: cancellation and non-measurement errors are never sub-floor skips.
ok(!main::autocal_nearblack_unmeasurable_skip({},"sdr",$step_nb,0.0117,"Auto Cal cancelled",1),
   'never skips a cancellation');
ok(!main::autocal_nearblack_unmeasurable_skip({},"sdr",$step_nb,0.0117,"SDR26 1D DPG upload failed",1),
   'never skips an upload/endpoint failure');
ok(!main::autocal_nearblack_unmeasurable_skip({},"sdr",$step_nb,0.0117,"",1),
   'never skips with an empty reason');
ok(!main::autocal_nearblack_unmeasurable_skip({},"sdr",$step_nb,undef,$UNMEASURABLE,1),
   'never skips when the expected luminance is unknown');
# Config knobs.
ok(!main::autocal_nearblack_unmeasurable_skip({lg_autocal_sdr26_dpg_nearblack_skip_max_ire=>0},"sdr",$step_nb,0.0117,$UNMEASURABLE,1),
   'an operator can disable the skip by setting the IRE cap to 0');
ok(main::autocal_nearblack_unmeasurable_skip({lg_autocal_sdr26_dpg_nearblack_skip_floor_margin=>100},"sdr",$step_nb,0.05,$UNMEASURABLE,1),
   'a wider floor margin lets a slightly brighter near-black patch skip');
# HDR20 uses the same gate.
ok(main::autocal_nearblack_unmeasurable_skip({},"hdr20",$step_nb,0.0117,"No usable meter measurement for 2.3% after 4 sample attempts",1),
   'HDR20 honours the same near-black skip gate');
# Guard 4b: the low-shadow ladder returns the SAME prefix whether the samples
# were valid-but-sub-floor (clean, no suffix -> skippable) or the ladder was
# exhausted by an underlying meter/comms/signal error (which it appends after
# "meter alignment"). A suffix means a real fault drove the failure -> abort.
my $CLEAN="No usable meter measurement for sdr26_2.3% after 4 sample attempts; check the signal range, displayed patch and meter alignment";
ok(main::autocal_nearblack_unmeasurable_skip({},"sdr",$step_nb,0.0117,$CLEAN,1),
   'skips the CLEAN ladder-exhaustion message (valid-but-sub-floor samples)');
ok(!main::autocal_nearblack_unmeasurable_skip({},"sdr",$step_nb,0.0117,$CLEAN.": spotread communication timeout",1),
   'never skips when the ladder appended a transient meter/comms error');
ok(!main::autocal_nearblack_unmeasurable_skip({},"sdr",$step_nb,0.0117,$CLEAN.": Pattern rejected",1),
   'never skips when the ladder appended a hard (non-transient) read error');

# ---------------------------------------------------------------------------
# 3. The read-failure router: skip records the patch + throws the sentinel;
#    a non-skip defers to the unchanged fatal path.
# ---------------------------------------------------------------------------
for my $prefix (qw(sdr hdr20)) {
 my $state={};
 my $marker=eval { main::autocal_dpg_read_failure_or_skip($state,{},$prefix,$step_nb,21,"sdr26_2.3%",0.0117,$UNMEASURABLE,1); 1 };
 ok(!$marker,"$prefix near-black skip throws rather than returning");
 ok(main::autocal_nearblack_skip_marker($@),"$prefix throws the skip SENTINEL (a ref), not a fatal string");
 is(ref($state->{"${prefix}_1d_dpg_skipped_anchors"}),"ARRAY","$prefix records the skipped anchor list");
 is($state->{"${prefix}_1d_dpg_skipped_anchors"}[0]{ire},2.3,"$prefix records the skipped patch IRE");
 ok(!$state->{"phase"} || $state->{"phase"} ne "error","$prefix skip does NOT set the fatal error phase");
}
{
 # A mid patch that cannot be read is a genuine fault: the router defers to the
 # fatal path (a plain string die, phase=error), exactly as before the fix.
 my $state={};
 eval { main::autocal_dpg_read_failure_or_skip($state,{},"sdr",{name=>"50%",ire=>50},512,"sdr26_50%",22.7,$UNMEASURABLE,1) };
 ok(!main::autocal_nearblack_skip_marker($@),'a mid patch is NOT carried forward');
 like($@,qr/measurement failed at sdr26_50%.*No usable meter measurement/,'mid patch aborts through the normal fatal message');
 is($state->{"sdr_1d_dpg_exit_reason"},"read_failed",'mid patch keeps the machine-readable failure cause');
}

# ---------------------------------------------------------------------------
# 4. End-to-end SDR26 greyscale: an unmeasurable deepest near-black patch does
#    NOT abort the job; a mid patch still does. This is the observed C1 case.
# ---------------------------------------------------------------------------
sub run_sdr26 {
 my ($fail_ire,%opt)=@_;
 my $state={};
 my $clean="; check the signal range, displayed patch and meter alignment";
 my $suffix=defined($opt{fail_suffix}) ? $opt{fail_suffix} : "";
 my %valid_seen;
 # Read every patch as a plausible BT.1886 luminance so the sweep converges
 # quickly -- except the target IRE, which is physically unmeasurable. With
 # valid_first set, the target IRE returns ONE barely-valid read (as a patch
 # right at the floor would) before going unmeasurable -- this is the case that
 # can leave a partial correction behind if the skip does not restore the curve.
 local *main::read_step=sub {
  my ($config,$rs,$st)=@_;
  my $ire=defined($rs->{ire})?($rs->{ire}+0):50;
  if(abs($ire-$fail_ire) < 0.01) {
   if($opt{valid_first} && !$valid_seen{sprintf("%.3f",$ire)}++) {
    return ({X=>0.02*0.95,Y=>0.02,Z=>0.02*1.09,x=>0.3127,y=>0.329,luminance=>0.02},undef);
   }
   return (undef,"No usable meter measurement for ".($rs->{name}||"patch")." after 4 sample attempts".$clean.$suffix);
  }
  my $y=($ire/100.0)**2.4*100.0; $y=0.0005 if($y<=0);
  return ({X=>$y*0.95,Y=>$y,Z=>$y*1.09,x=>0.3127,y=>0.329,luminance=>$y},undef);
 };
 local *main::api_json=sub { return {status=>'ok'}; };
 # The full greyscale path emits a pre-existing "isn't numeric" warning from one
 # specific internal range check (line 1342) unrelated to this fix; suppress
 # only that exact line so any NEW numeric warning from the change still surfaces.
 local $SIG{__WARN__}=sub { warn $_[0] unless $_[0]=~/isn't numeric in int at .*meter_lg_autocal\.pl line 1342/; };
 my $config={ signal_mode=>'sdr', ddc_layout=>'sdr26', target_gamma=>'bt1886',
  max_bpc=>10, pattern_signal_range=>2, signal_range=>2, transport_signal_range=>2,
  color_format=>0, lg_autocal_26=>1, black_y=>0, target_delta_e=>0.5 };
 my ($err,$died);
 { local $@; $err=eval { main::lg_autocal_26_run_sdr_1d_dpg_greyscale($config,$state,100,0.3127,0.329,'filmMaker') }; $died=$@; }
 return ($err,$died,$state);
}

{
 # Deepest near-black (2.3%) unmeasurable -> carried forward, job completes.
 my ($err,$died,$state)=run_sdr26(2.3);
 is($died,'','the greyscale does NOT die when the deepest near-black patch is unmeasurable');
 is($err,undef,'and it returns success (no terminal error) so the LUT still commits');
 ok($state->{sdr_1d_dpg_uploaded},'the 1D DPG is reported uploaded (the sweep produced a curve)');
 is(ref($state->{sdr_1d_dpg_skipped_anchors}),"ARRAY",'the skipped patch is recorded for the operator');
 is(scalar(@{$state->{sdr_1d_dpg_skipped_anchors}||[]}),1,'exactly the one deepest near-black patch was skipped');
 is($state->{sdr_1d_dpg_skipped_anchors}[0]{ire},2.3,'and it is the 2.3% patch');
 like($state->{message},qr/left uncorrected/,'the completion message discloses the carried-forward patch');
}
{
 # A mid patch (50%) unmeasurable -> real fault -> the whole job still aborts.
 my ($err,$died,$state)=run_sdr26(50);
 like($died,qr/measurement failed at .*50%.*No usable meter measurement/,'a mid patch that cannot be read STILL aborts the whole greyscale');
 ok(!$state->{sdr_1d_dpg_skipped_anchors} || !@{$state->{sdr_1d_dpg_skipped_anchors}},'nothing is silently carried forward on a genuine mid-patch fault');
}
{
 # A near-black patch whose ladder exhaustion carries a meter/comms error suffix
 # is a real fault, not sub-floor darkness -> the whole job STILL aborts.
 my ($err,$died,$state)=run_sdr26(2.3, fail_suffix=>": spotread communication timeout");
 like($died,qr/measurement failed at .*2\.3%/,'a comms/hardware fault at the deepest near-black patch STILL aborts (not masked as sub-floor)');
 ok(!$state->{sdr_1d_dpg_skipped_anchors} || !@{$state->{sdr_1d_dpg_skipped_anchors}},'a meter fault at 2.3% is not silently carried forward');
}
{
 # The partial-correction guard: a near-black patch that gives ONE barely-valid
 # read (which uploads a provisional gain) before going sub-floor must land on
 # the SAME committed curve as a patch that was unmeasurable from the first read
 # -- i.e. genuinely uncorrected, with no partial move baked in.
 my (undef,$died_a,$state_a)=run_sdr26(2.3);                     # unmeasurable from the first read
 my (undef,$died_b,$state_b)=run_sdr26(2.3, valid_first=>1);     # one valid read, then sub-floor
 is($died_a,'','control run (fail-first) completes');
 is($died_b,'','valid-then-fail run completes');
 is_deeply($state_b->{sdr_1d_dpg_data},$state_a->{sdr_1d_dpg_data},
  'a partial correction from an early barely-valid read is NOT baked into the committed curve (patch truly left uncorrected)');
}

# ---------------------------------------------------------------------------
# 5. Load-bearing call sites (a passing suite must not survive their deletion).
#    Model: t/idle_pattern_seed.t asserts the caller body contains the call.
# ---------------------------------------------------------------------------
my $src=do { open(my $fh,'<',"$Bin/../usr/bin/meter_lg_autocal.pl") or die $!; local $/; <$fh> };

# The SDR inner routes read failures through the gate, never the bare fatal call.
ok($src =~ /my \$_sdr_read_failure=sub \{/, 'SDR inner defines the near-black read-failure router');
ok(index($src,'$_sdr_read_failure->($err)') >= 0, 'SDR inner main read routes through the router');
ok(index($src,'$_sdr_read_failure->($are)') >= 0, 'SDR inner revert re-read routes through the router');
ok($src !~ /autocal_dpg_read_failure\(\$state,"sdr"/, 'no bare SDR fatal read-failure call remains');

# The HDR calibrate_anchor routes read failures through the gate; only the
# outer provisional 100% white-reference read stays a hard abort (never skippable).
ok($src =~ /my \$_hdr_read_failure=sub \{/, 'HDR calibrate_anchor defines the near-black read-failure router');
ok(index($src,'$_hdr_read_failure->(') >= 0, 'HDR read sites route through the router');
my @hdr_fatal=($src =~ /autocal_dpg_read_failure\(\$state,"hdr20"([^\n]*)/g);
is(scalar(@hdr_fatal),1,'exactly one bare HDR fatal call remains (the 100% white reference)');
like($hdr_fatal[0],qr/100% white reference/,'and it is the white-reference seed read, which is never skippable');

# Both outer loops catch the skip sentinel and continue the sweep.
ok($src =~ /autocal_nearblack_skip_marker\(\$_e\)/, 'an outer loop distinguishes the skip sentinel from a fatal die');
my @markers=($src =~ /if\(!autocal_nearblack_skip_marker\(\$_e\)\)/g);
ok(scalar(@markers) >= 2, 'both the SDR and HDR outer loops re-propagate real fatal errors unchanged');

done_testing();
