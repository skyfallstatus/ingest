#!/usr/bin/perl
# Runs a test run and stops all of it if the Mac is in trouble. See scripts/test.sh, which starts this.
#
# This is Perl because of what it's for. When a Mac can't start processes, a failed fork ends a zsh script on the spot, which would
# take the watchdog with it and leave the tests running. Here `fork` just returns nothing, and everything on the way out, `kill`,
# `sleep` and removing files, is done in this process. Only plain `fork` is used: Perl's `system` and piped `open` wait and try
# again when a fork fails, and `system` does that for ever.
use strict;
use warnings;
use POSIX qw(setsid _exit WNOHANG);
use File::Path qw(remove_tree);
use Time::HiRes qw(sleep time);

my ($BEFORE, $FLOOR, $DROP, $LIMIT, $SPAWN, $DISK, $RUN, $LOCK) = @ENV{qw(WATCH_BEFORE WATCH_FLOOR WATCH_DROP WATCH_LIMIT WATCH_SPAWN WATCH_DISK WATCH_RUN WATCH_LOCK)};
my $COMMAND = $ENV{INGEST_TEST_COMMAND};
my $started = time;
$| = 1;

# Starts a program and returns what it printed, or nothing at all if it couldn't be started.
sub capture {
    my @command = @_;
    pipe(my $from, my $to) or return undef;
    my $p = fork();
    return undef unless defined $p;
    if ($p == 0) {
        close $from;
        open(STDOUT, '>&', $to);
        open(STDERR, '>', '/dev/null');
        { no warnings 'exec'; exec { $command[0] } @command; }
        _exit(127);
    }
    close $to;
    my @lines = <$from>;
    close $from;
    waitpid($p, 0);
    return $? == 0 ? \@lines : undef;
}

sub cleanup {
    unless (defined $COMMAND && length $COMMAND) {       # images this run made, if it was stopped before it could take them away
        for my $folder (glob '/private/tmp/ingest-image-*') {
            next unless -d $folder && (stat $folder)[9] >= int $started;
            capture('/usr/bin/hdiutil', 'detach', '-quiet', '-force', "$folder/m");
            remove_tree($folder, { safe => 0 });
        }
    }
    remove_tree($RUN, $LOCK, { safe => 0 });
}

# Asks for a process to be started, and for it to finish well. Anything else is a Mac in trouble.
sub spawns {
    my $p = fork();
    return 0 unless defined $p;
    if ($p == 0) {
        open(STDERR, '>', '/dev/null');
        { no warnings 'exec'; exec { $SPAWN } $SPAWN; }
        _exit(127);
    }
    return waitpid($p, 0) == $p && $? == 0;
}

# Free megabytes, or nothing if that can't be found out.
sub free_mb {
    my $lines = capture('/bin/df', '-m', $DISK) or return undef;
    return @$lines >= 2 ? (split ' ', $lines->[1])[3] : undef;
}

# Everything under a process. It's a second way of reaching them, and nothing if it can't be looked up.
sub tree {
    my ($parent) = @_;
    my $lines = capture('/usr/bin/pgrep', '-P', $parent) or return ();
    my @children = map { chomp; $_ } @$lines;
    return ((map { tree($_) } @children), @children);
}

sub stop_all {
    my ($pid, $signal) = @_;
    kill $signal, -$pid;        # the session first, which needs nothing new
    kill $signal, tree($pid), $pid;
}

my $pid = fork();
unless (defined $pid) { print STDERR "test.sh: a new process couldn't be started, so this Mac is in trouble. Not starting.\n"; cleanup(); exit 97; }
if ($pid == 0) {
    setsid();           # its own session, so stopping it stops everything it started
    no warnings 'exec';
    if (defined $COMMAND && length $COMMAND) { exec '/bin/zsh', '-c', $COMMAND; }
    else { exec { $ARGV[0] } @ARGV; }
    _exit(127);
}

for my $name (qw(INT TERM HUP)) {
    $SIG{$name} = sub { stop_all($pid, 'KILL'); cleanup(); exit 130; };
}

my ($why, $code);
while (1) {
    if (waitpid($pid, WNOHANG) == $pid) {
        my $status = $?;
        cleanup();
        exit($status & 127 ? 128 + ($status & 127) : $status >> 8);
    }
    if (!spawns()) {
        ($why, $code) = ("a new process couldn't be started, so this Mac is in trouble", 97);
    } elsif (time - $started > $LIMIT) {
        ($why, $code) = ("it's been running for more than $LIMIT seconds, which is the limit", 98);
    } else {
        my $now = free_mb();
        if (!defined $now) { ($why, $code) = ("the free space on $DISK can't be read any more", 99); }
        elsif ($now < $FLOOR) { ($why, $code) = (sprintf("only %d GB is free on %s, below the %d GB floor", $now / 1024, $DISK, $FLOOR / 1024), 99); }
        elsif ($BEFORE - $now > $DROP) { ($why, $code) = (sprintf("free space on %s fell by %d GB, more than the %d GB a run may use", $DISK, ($BEFORE - $now) / 1024, $DROP / 1024), 99); }
    }
    last if defined $why;
    sleep 1;
}

print STDERR "test.sh: stopping the whole run: $why.\n";
stop_all($pid, 'TERM');
sleep 2;
stop_all($pid, 'KILL');
waitpid($pid, WNOHANG);
cleanup();
exit $code;             # never a blocking wait: a stuck process mustn't keep this running
