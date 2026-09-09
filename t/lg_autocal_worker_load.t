#!/usr/bin/perl
# Smoke test: each AutoCal worker loads as a module without running main.
#
# Both scripts end in `unless(caller()) { ... }`, so `do` defines their subs
# without starting a calibration. That is what makes the rest of the suite
# possible. Load ONE worker per test file -- the two define overlapping names
# in main:: and loading both in one interpreter emits redefinition warnings.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More tests => 4;

my $worker = "$Bin/../usr/bin/meter_lg_autocal.pl";
ok(-f $worker, 'meter_lg_autocal.pl is present');

my $rc = do $worker;
ok(defined $rc, 'loads without dying') or diag("error: $@");
is($@, '', 'loads with no error');

no strict 'refs';
my $subs = grep { defined &{"main::$_"} } keys %main::;
cmp_ok($subs, '>', 500, "worker subs are visible to the harness ($subs found)");
