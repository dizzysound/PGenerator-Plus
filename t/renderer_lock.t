#!/usr/bin/perl
# One renderer at a time.
#
# Two renderers on the same CRTC oopsed vc4 (drm_atomic_set_crtc_for_plane) and
# left the renderer in D state until a reboot. The way in was a lock kept in
# $var_dir/running/: clean_files() deletes every plain file there on each
# renderer stop, so a later WebUI apply worker locked a fresh inode while the
# first still held the old one, and both went on to start a renderer.
#
# These tests pin the properties that close it: lock files live where
# clean_files() cannot reach them, start and stop share one lock that nests for
# the same thread, a start is skipped while a renderer runs, an error inside
# start/stop still releases the lock, and a forked child does not keep the
# parent's lock alive.
use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Fcntl qw(:flock);
use POSIX ();
use Test::More tests => 29;

my $dir = "$Bin/../usr/share/PGenerator";
unshift @INC, $dir;

our ($debug, $var_dir, $pattern_generator);
$debug = 0;
my $tmp = tempdir(CLEANUP => 1);
$var_dir = "$tmp/";
mkdir "$tmp/running";

for my $m (qw(log.pm file.pm command.pm)) {
  my $rc = do "$dir/$m";
  ok(defined $rc, "$m loads") or diag("error: $@");
}
for my $f (qw(pgen_lock_path renderer_lock renderer_unlock pgen_drop_inherited_locks
              pattern_generator_start pattern_generator_start_locked
              pattern_generator_stop pattern_generator_stop_locked)) {
  ok(defined &{"main::$f"}, "$f is defined");
}

# A second, independent open of the lock file: it can take the lock only while
# nobody holds it.
sub lock_is_free {
  my $path = shift;
  open(my $fh, '>', $path) or die "open $path: $!";
  my $ok = flock($fh, LOCK_EX | LOCK_NB) ? 1 : 0;
  close $fh;
  return $ok;
}

# --- lock files live outside what clean_files() empties ---
my $lock_path = pgen_lock_path("renderer.lock");
is($lock_path, "$tmp//locks/renderer.lock", 'lock path is under $var_dir/locks');
ok(-d "$tmp/locks", 'the locks directory is created on demand');
open(my $touch, '>', $lock_path) or die $!; close $touch;
open($touch, '>', "$tmp/running/plain.file") or die $!; close $touch;
remove_files("$tmp/", ".*");
remove_files("$tmp/running/", ".*");
ok(!-e "$tmp/running/plain.file", 'the blanket wipe still removes plain files');
ok(-e $lock_path, 'but a lock file in locks/ survives it');

# --- mutual exclusion, and nesting for the same thread ---
renderer_lock();
ok(!lock_is_free($lock_path), 'renderer_lock holds the lock');
renderer_lock();
renderer_unlock();
ok(!lock_is_free($lock_path), 'a nested unlock keeps the lock (stop -> start nests)');
renderer_unlock();
ok(lock_is_free($lock_path), 'the outermost unlock releases it');
renderer_unlock();
ok(lock_is_free($lock_path), 'an unbalanced unlock is harmless');

# --- a start is skipped while a renderer runs ---
no warnings 'redefine';
my $ran = 0;
*main::pattern_generator_start_locked = sub (@) { $ran++; return 1 };
*main::pattern_generator_stop_locked  = sub { $ran++; return 1 };
*main::pattern_generator_is_running   = sub () { return 1 };
pattern_generator_start();
is($ran, 0, 'start does nothing while a renderer is running');
ok(lock_is_free($lock_path), 'and releases the lock on the way out');

*main::pattern_generator_is_running = sub () { return 0 };
pattern_generator_start();
is($ran, 1, 'start runs when no renderer is running');
ok(lock_is_free($lock_path), 'and releases the lock afterwards');

# --- an error inside start or stop must not leave the lock held ---
*main::pattern_generator_start_locked = sub (@) { die "boom\n" };
*main::pattern_generator_stop_locked  = sub { die "bang\n" };
ok(!eval { pattern_generator_start(); 1 } && $@ eq "boom\n", 'an error in start is rethrown');
ok(lock_is_free($lock_path), 'and the lock is released');
ok(!eval { pattern_generator_stop(); 1 } && $@ eq "bang\n", 'an error in stop is rethrown');
ok(lock_is_free($lock_path), 'and the lock is released');

# --- a forked child must not keep the parent's lock alive ---
renderer_lock();
pipe(my $r, my $w) or die $!;
my $pid = fork();
die "fork: $!" if !defined $pid;
if ($pid == 0) {
  close $w;
  pgen_drop_inherited_locks();
  my $holds = 0;
  if (opendir(my $fds, "/proc/self/fd")) {
    for my $fd (readdir $fds) {
      next if $fd !~ /^\d+$/;
      my $t = readlink("/proc/self/fd/$fd");
      $holds++ if defined $t && $t =~ m{/locks/};
    }
  }
  sysread($r, my $buf, 1);
  POSIX::_exit($holds ? 1 : 0);
}
close $r;
renderer_unlock();
ok(lock_is_free($lock_path), 'the lock is free once the parent unlocks, with the child alive');
close $w;
waitpid($pid, 0);
is($? >> 8, 0, 'a child that dropped inherited locks holds no descriptor in locks/');
