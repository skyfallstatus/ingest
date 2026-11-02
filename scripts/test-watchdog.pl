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
my ($finished, $guard, $refused);
$| = 1;

# Starts a program and returns what it printed, or nothing at all if it couldn't be started.
sub capture {
    my @command = @_;
    pipe(my $from, my $to) or return undef;
    my $p = fork();
    $refused = 1 unless defined $p;
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

# Everything the run has started and that's still alive, and the process group each one is in, kept up to date once a second. It
# can't be left until the moment of stopping. A process can leave the run's group, which `swift test` does with its test process, and
# when its parent goes it's handed to launchd, so nothing leads to it from the top any more. And on a Mac that can't start `ps` this
# list is all there is, so a failed look keeps the last one. The walk starts from what's known as well as from the top, for the same
# reason, and only what's alive stays on it, so it never holds a number that has gone on to another process.
my ($pid, %known);
sub look {
    my $lines = capture('/bin/ps', '-axo', 'pid=', '-o', 'ppid=', '-o', 'pgid=') or return;
    my (%group, %under, %found);
    for (@$lines) {
        my ($p, $parent, $g) = split;
        $group{$p} = $g;
        push @{ $under{$parent} }, $p;
    }
    my @walk = ($pid, keys %known);
    while (defined(my $p = shift @walk)) {
        next if !defined $group{$p} || exists $found{$p};
        $found{$p} = $group{$p};
        push @walk, @{ $under{$p} || [] };
    }
    %known = %found;
}

# Looks first: once a signal has ended the top of the run, what's under it can't be traced to it.
sub stop_all {
    my ($signal) = @_;
    look();
    my %groups = map { $_ => 1 } $pid, grep { $_ > 1 && $_ != getpgrp() } values %known;    # these need nothing new, and reach what's younger than the list
    kill $signal, map { -$_ } keys %groups;
    kill $signal, $pid, keys %known;
}

$pid = fork();
unless (defined $pid) { print STDERR "test.sh: a new process couldn't be started, so this Mac is in trouble. Not starting.\n"; cleanup(); exit 97; }
if ($pid == 0) {
    setsid();           # its own group, which can be signalled whole. Whatever leaves that group is found by `look`
    no warnings 'exec';
    if (defined $COMMAND && length $COMMAND) { exec '/bin/zsh', '-c', $COMMAND; }
    else { exec { $ARGV[0] } @ARGV; }
    _exit(127);
}

# This process can be killed too, and then nothing would be watching the run. So a second one waits here for it to go, and if it goes
# without saying it's finished, stops the run. It has a session of its own, so killing this one's group doesn't reach it.
$guard = pipe(my $waiting, $finished) ? fork() : undef;      # a Mac that can't do this is caught by the first check below
if (defined $guard && $guard == 0) {
    setsid();
    $SIG{$_} = 'IGNORE' for qw(INT TERM HUP PIPE);
    close $finished;
    unless (defined <$waiting>) {
        print STDERR "test.sh: the watchdog was killed, so the whole run is being stopped.\n";
        stop_all('KILL');
        cleanup();
    }
    _exit(0);
}
close $waiting if defined $guard;
END { local $SIG{PIPE} = 'IGNORE'; syswrite($finished, "finished\n") if $guard; }

for my $name (qw(INT TERM HUP)) {
    $SIG{$name} = sub { stop_all('KILL'); cleanup(); exit 130; };
}

my ($why, $code);
while (1) {
    look();
    if (waitpid($pid, WNOHANG) == $pid) {
        my $status = $?;
        stop_all('KILL');       # nothing a run started outlasts it
        cleanup();
        exit($status & 127 ? 128 + ($status & 127) : $status >> 8);
    }
    my $can_start = spawns();
    my $now = free_mb();
    if (!$can_start || $refused) {      # any process at all: on a Mac near its limit, one can get through and the next not
        ($why, $code) = ("a new process couldn't be started, so this Mac is in trouble", 97);
    } elsif (time - $started > $LIMIT) {
        ($why, $code) = ("it's been running for more than $LIMIT seconds, which is the limit", 98);
    } else {
        if (!defined $now) { ($why, $code) = ("the free space on $DISK can't be read any more", 99); }
        elsif ($now < $FLOOR) { ($why, $code) = (sprintf("only %d GB is free on %s, below the %d GB floor", $now / 1024, $DISK, $FLOOR / 1024), 99); }
        elsif ($BEFORE - $now > $DROP) { ($why, $code) = (sprintf("free space on %s fell by %d GB, more than the %d GB a run may use", $DISK, ($BEFORE - $now) / 1024, $DROP / 1024), 99); }
    }
    last if defined $why;
    sleep 1;
}

print STDERR "test.sh: stopping the whole run: $why.\n";
stop_all('TERM');
sleep 2;
stop_all('KILL');
waitpid($pid, WNOHANG);
cleanup();
exit $code;             # never a blocking wait: a stuck process mustn't keep this running
