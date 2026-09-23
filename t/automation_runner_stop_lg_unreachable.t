use strict;
use warnings;
use FindBin qw($Bin);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
use JSON::PP ();
use POSIX ();

# Stop and automatic-failure cleanup against a TV that does not answer. Since
# /api/lg/status reports a sleeping TV as not connected, every LG call made
# during cleanup used to run its own three-attempt reconnect (~60s each), and
# the Dolby Vision worker stop made the other worker stops and the meter
# release wait behind them.
local $ENV{PGEN_AUTOMATION_DIR} = tempdir(CLEANUP => 1);
PGAutomation::ensure_store();
my $run_id = 'stop-lg-unreachable';
make_path(PGAutomation::run_dir($run_id) . '/items');
{
 local @ARGV = ($run_id, 'token-for-stop-test');
 local $SIG{__WARN__} = sub {};
 do "$Bin/../usr/bin/pgen_automation_runner.pl";
 die "runner failed to load: $@" if $@;
}

ok(!main::_lg_action_path('/api/lg/dv-profile/stop'), 'the DV worker stop does not need the TV');
ok(!main::_lg_action_path('/api/lg/dv-profile/kill'), 'the DV worker kill does not need the TV');
ok(main::_lg_action_path('/api/lg/calibration-mode'), 'CAL_END still reconnects first');
ok(main::_lg_action_path('/api/lg/autocal/run/end'), 'run/end closes calibration mode on the TV, so it still reconnects first');

# Runs the real _stop_active() against a stubbed daemon. $tv: 'asleep' never
# connects; 'refuses-once' connects, then refuses the first CAL_END. Each run
# is in a child: _stop_active() runs once per process ($STOP_HANDLED).
sub stop_sequence {
 my (%opt) = @_;
 pipe(my $r, my $w) or die "pipe: $!";
 my $pid = fork() // die "fork: $!";
 if (!$pid) {
  close $r;
  my ($seq, $logs) = stop_sequence_in_child(%opt);
  print {$w} JSON::PP->new->encode({seq=>$seq,logs=>$logs});
  close $w;
  POSIX::_exit(0);
 }
 close $w;
 my $json = do { local $/; <$r> };
 waitpid($pid, 0);
 my $out = JSON::PP->new->decode($json || '{"seq":[],"logs":["child failed"]}');
 return ($out->{seq}, $out->{logs});
}

sub stop_sequence_in_child {
 my (%opt) = @_;
 no warnings qw(redefine once);
 my (@seq, @logs);
 my $cal_calls = 0;
 my $run = {id=>$run_id,status=>'running',items=>[],lg_run_id=>'x'};
 local *main::_log = sub { push @logs, $_[0] };
 local *main::_log_action = sub {};
 local *main::_stop_progress = sub {};
 local *main::_run = sub { $run };
 local *main::_update_run = sub { $_[0]->($run); $run };
 local *main::_worker_process_alive = sub { 0 };
 local *main::_refresh_control = sub {};
 local *main::_heartbeat = sub {};
 local *main::_sleep_controlled = sub { return 0 if $opt{user_stop} && !$_[1]; 1 };
 local *main::_api_once = sub {
  my ($method, $path) = @_;
  my $up = $opt{tv} ne 'asleep';
  return {status=>'ok',paired=>1,connected=>0,stored_ip=>'192.0.2.1',calibration_mode=>0}
   if $path eq '/api/lg/status';
  push @seq, $path eq '/api/lg/connect' ? 'CONNECT' : $path;
  my $refused = {status=>'error',message=>'Unable to connect to LG WebOS TV at 192.0.2.1',delivery_state=>'not-sent'};
  return $up ? {status=>'ok',connected=>1} : {%$refused,connected=>0} if $path eq '/api/lg/connect';
  if ($path eq '/api/lg/calibration-mode') {
   $cal_calls++;
   return $refused if !$up || ($opt{tv} eq 'refuses-once' && $cal_calls == 1);
  }
  return {status=>'ok'};
 };
 main::_stop_active();
 my @short = map { (my $s = $_) =~ s{^/api/}{}; $s } @seq;
 return (\@short, \@logs);
}

sub connects { scalar grep { $_ eq 'CONNECT' } @{$_[0]} }
sub before_meter_release {
 my ($seq) = @_;
 my @before;
 for (@$seq) { last if $_ eq 'meter/session/stop'; push @before, $_ }
 return connects(\@before);
}

{
 my ($seq, $logs) = stop_sequence(tv=>'asleep');
 is(before_meter_release($seq), 0, 'failure cleanup: workers stop and the meter is released before any TV reconnect');
 is(connects($seq), 3, 'failure cleanup: one three-attempt reconnect, not one per LG call');
 ok((grep { $_ eq 'lg/calibration-mode' } @$seq), 'failure cleanup still sends CAL_END');
 ok((grep { $_ eq 'lg/autocal/run/end' } @$seq), 'failure cleanup still ends the LG run');
 is(scalar(grep { /skipping further LG reconnects/ } @$logs), 1, 'the skipped reconnects are logged once');
}
{
 my ($seq) = stop_sequence(tv=>'asleep', user_stop=>1);
 is(before_meter_release($seq), 0, 'user Stop: workers stop and the meter is released before any TV reconnect');
 is(connects($seq), 1, 'user Stop: a single reconnect attempt');
}
{
 my ($seq) = stop_sequence(tv=>'refuses-once');
 is(scalar(grep { $_ eq 'lg/calibration-mode' } @$seq), 2, 'an answering TV that refuses one CAL_END still gets the retry');
 is(connects($seq), 2, 'the retry refreshes the pairing, because the TV answered');
}

# Normal end-of-batch restoration also sets $STOPPING, and a transient refusal
# after a picture-mode switch must keep its per-call reconnect there.
my $runner = do { local $/; open(my $fh, '<', "$Bin/../usr/bin/pgen_automation_runner.pl") or die $!; <$fh> };
like($runner, qr/my \$stop_cleanup = \$STOPPING && \$STOP_HANDLED;/, 'the skip applies only inside Stop/failure cleanup');

done_testing;
