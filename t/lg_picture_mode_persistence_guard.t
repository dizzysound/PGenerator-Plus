#!/usr/bin/perl
# Regression guard for the picture-mode contamination bug.
#
# On a ddc_only set (e.g. a 2021 C1) a picture read answers
# virtual_picture_settings, where pictureMode is PGenerator's OWN resolved DDC
# target, not something the TV said. Persisting that via lgRememberPictureMode
# poisons the stored per-signal preference and silently replaces the operator's
# selection -- and Full Auto Cal then calibrates the wrong mode for an hour.
#
# webui-lg.js has three sites that persist a picture mode from a read/set
# response: lgRefreshPictureMode, lgDisplayControlRefresh, lgDisplayControlSet.
# Every one must gate on virtual_picture_settings. The original fix guarded
# only the first; this test fails if any site regresses or a new unguarded one
# is added.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More tests => 7;

my $js = "$Bin/../usr/share/PGenerator/webui-lg.js";
ok(-f $js, 'webui-lg.js is present');
open(my $fh,'<',$js) or die "read $js: $!";
local $/; my $src=<$fh>; close($fh);

# The three guarded forms that must be present.
like($src, qr/r\.picture_settings\.pictureMode\s*&&\s*!r\.virtual_picture_settings/,
     'lgDisplayControlRefresh gates its readback persist on virtual_picture_settings');
like($src, qr/picture\.pictureMode\s*&&\s*!r\.virtual_picture_settings/,
     'lgDisplayControlSet gates its readback persist on virtual_picture_settings');
like($src, qr/r\.virtual_picture_settings\s*\?\s*''\s*:\s*mode/,
     'lgRefreshPictureMode blanks a virtual readback before persisting');

# The unguarded forms that used to poison the preference must be gone. Both
# were `if(<readback>.pictureMode){` with no virtual_picture_settings gate.
unlike($src, qr/if\(r\.picture_settings\.pictureMode\)\{/,
       'no unguarded lgRememberPictureMode persist from r.picture_settings.pictureMode');
unlike($src, qr/if\(picture\.pictureMode\)\{/,
       'no unguarded lgDisplayControlSet persist from picture.pictureMode');

# --- every persistence site must be gated, not just the two known old forms ---
#
# The regex assertions above pin the specific sites fixed so far, but they would
# not catch a NEW ungated persistence site (as one at lgResetPictureMode showed).
# Enumerate every lgRememberPictureMode call and require a gate token within the
# few lines above it: virtual_picture_settings / picture_mode_readable /
# picture_mode_verified, or `readback` (the pre-blanked value). The function
# definition itself is exempt.
my @lines = split /\n/, $src;
my @ungated;
for my $i (0 .. $#lines) {
 next unless $lines[$i] =~ /lgRememberPictureMode\(/;
 next if $lines[$i] =~ /function\s+lgRememberPictureMode/;
 my $lo = $i - 8; $lo = 0 if $lo < 0;
 my $window = join "\n", @lines[$lo .. $i];
 push @ungated, ($i + 1)
   unless $window =~ /virtual_picture_settings|picture_mode_readable|picture_mode_verified|readback/;
}
is(scalar(@ungated), 0,
   'every lgRememberPictureMode persist is gated (ungated lines: '.(join(',',@ungated) || 'none').')');
