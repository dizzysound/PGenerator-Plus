#!/usr/bin/perl
# Companion to lg_autocal_worker_load.t for the 3D worker, in its own
# interpreter so the two workers' overlapping sub names never collide.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More tests => 3;

my $worker = "$Bin/../usr/bin/meter_lg_3d_autocal.pl";
ok(-f $worker, 'meter_lg_3d_autocal.pl is present');
my $rc = do $worker;
ok(defined $rc, 'loads without dying') or diag("error: $@");
is($@, '', 'loads with no error');
