#!/usr/bin/perl
# Pins PGMath::delta_e_itp_xyz against an independent BT.2100 ICtCp
# implementation written from the standard. Guards the grading maths against
# silent drift of the kind PR 50 could have introduced.
use strict; use warnings;
use FindBin qw($Bin);
use lib "$Bin/../usr/share/PGenerator";
use Test::More tests => 5;
use PGMath qw(delta_e_itp_xyz);

# --- independent reference implementation (BT.2100) ---
my @M1 = ([0.3592,0.6976,-0.0358],[-0.1922,1.1004,0.0755],[0.0070,0.0749,0.8434]);
my ($m1,$m2,$c1,$c2,$c3) = (2610/16384, 2523/4096*128, 3424/4096, 2413/4096*32, 2392/4096*32);
sub pq { my $v=shift; $v=0 if $v<0; $v/=10000; my $n=$v**$m1; return (($c1+$c2*$n)/(1+$c3*$n))**$m2 }
sub ictcp {
    my ($X,$Y,$Z)=@_;
    my @lms = map { $M1[$_][0]*$X + $M1[$_][1]*$Y + $M1[$_][2]*$Z } 0..2;
    my ($L,$M,$S) = map { pq($_) } @lms;
    return (0.5*$L+0.5*$M, (6610*$L-13613*$M+7003*$S)/4096, (17933*$L-17390*$M-543*$S)/4096);
}
sub ref_deitp {
    my ($a,$b)=@_;
    my @p=ictcp(@$a); my @q=ictcp(@$b);
    return 720*sqrt(($p[0]-$q[0])**2 + 0.25*($p[1]-$q[1])**2 + ($p[2]-$q[2])**2);
}

# Real post-calibration readings from C1 run 20260908-181653-300002 (SDR),
# paired with D65 at the measured Y.
my @cases = (
    [[0.1336,0.1435,0.1598], 'SDR 5%'],
    [[3.6910,3.8850,4.2320], 'SDR 20%'],
    [[52.960,55.700,60.630], 'SDR 100%'],
    [[0.6800,0.7160,0.7800], 'SDR 10%'],
);
for my $c (@cases) {
    my ($xyz,$label)=@$c;
    my $Y=$xyz->[1];
    my @tgt = (0.3127/0.3290*$Y, $Y, (1-0.3127-0.3290)/0.3290*$Y);
    my $mine = ref_deitp($xyz,\@tgt);
    my $theirs = delta_e_itp_xyz(@$xyz, @tgt);
    cmp_ok(abs($mine-$theirs), '<', 0.001,
        sprintf('%s: PGMath %.6f matches reference %.6f', $label, $theirs, $mine));
}
cmp_ok(delta_e_itp_xyz(1,1,1,1,1,1), '<', 1e-9, 'identical XYZ gives dE 0');
