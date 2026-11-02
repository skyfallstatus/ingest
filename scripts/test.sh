#!/bin/zsh
# Runs the tests with Command Line Tools only. No Xcode needed.
#
# Some tests really do fill a disk image, and a test that lost its image once filled the Mac's own disk instead. So a run looks
# after the disk it's on. It won't start below 150 GB free. A watchdog stops the whole run, and says why, if free space falls by
# more than 40 GB or below 100 GB. Only one run goes at a time, and its scratch goes with it, however it ends.
#
# A smaller disk can ask for less, knowing what these are for, in megabytes:
#   INGEST_TEST_START_MB=60000 INGEST_TEST_FLOOR_MB=30000 scripts/test.sh
START_MB=${INGEST_TEST_START_MB:-153600}
FLOOR_MB=${INGEST_TEST_FLOOR_MB:-102400}
DROP_MB=${INGEST_TEST_DROP_MB:-40960}
LOCK=${INGEST_TEST_LOCK:-/private/tmp/ingest-test.lock}
DISK=/private/tmp       # where the images and the scratch go
JOBS=6

free_mb() { df -m $DISK 2>/dev/null | awk 'NR==2 { print $4 }' }

BEFORE=$(free_mb)
if [[ -z $BEFORE ]]; then echo "test.sh: can't read the free space on $DISK. Not starting." >&2; exit 1; fi
if (( BEFORE < START_MB )); then
  echo "test.sh: only $(( BEFORE / 1024 )) GB free on $DISK, and a run needs $(( START_MB / 1024 )) GB. Not starting." >&2
  echo "test.sh: free some room. On a small disk, see the top of this script." >&2
  exit 1
fi

if ! mkdir $LOCK 2>/dev/null; then
  HOLDER=$(cat $LOCK/pid 2>/dev/null)
  if [[ -n $HOLDER ]] && kill -0 $HOLDER 2>/dev/null; then
    echo "test.sh: another test run is going (process $HOLDER). One at a time." >&2
    exit 1
  fi
  rm -rf $LOCK                                  # left by a run that died
  mkdir $LOCK || { echo "test.sh: couldn't take $LOCK." >&2; exit 1 }
fi
echo $$ > $LOCK/pid

RUN=$(mktemp -d "${TMPDIR:-/tmp/}ingest-test-run.XXXXXX")
touch $RUN/started
export TMPDIR="$RUN/"

cleanup() {
  trap - EXIT INT TERM HUP
  if [[ -z $INGEST_TEST_COMMAND ]]; then        # images this run made, if it was stopped before it could take them away
    for folder in /private/tmp/ingest-image-*(N/); do
      [[ $folder -nt $RUN/started ]] || continue
      hdiutil detach -quiet -force $folder/m 2>/dev/null
      rm -rf $folder
    done
  fi
  rm -rf $RUN $LOCK
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP

F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib

# Its own session, so stopping it stops everything it started. Job control can't do this: it needs a terminal, and scripts and CI have none.
NEW_SESSION=(/usr/bin/perl -e 'use POSIX; POSIX::setsid(); exec @ARGV or exit 127' --)
if [[ -n $INGEST_TEST_COMMAND ]]; then
  $NEW_SESSION zsh -c "$INGEST_TEST_COMMAND" &
else
  $NEW_SESSION swift test -j $JOBS --no-parallel "$@" --disable-xctest -Xswiftc -F$F -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing -Xlinker -F$F -Xlinker -rpath -Xlinker $F -Xlinker -rpath -Xlinker $L &
fi
PID=$!

# Everything under a process, deepest first.
tree() { local child; for child in $(pgrep -P $1); do tree $child; echo $child; done }

# The session, and the tree as well in case something left it.
stop() {
  local everything=($(tree $PID) $PID)
  kill -$1 -- -$PID 2>/dev/null
  kill -$1 $everything 2>/dev/null
}

WHY=""
while kill -0 $PID 2>/dev/null; do
  NOW=$(free_mb)
  if [[ -z $NOW ]]; then WHY="the free space on $DISK can't be read any more"
  elif (( NOW < FLOOR_MB )); then WHY="only $(( NOW / 1024 )) GB is free on $DISK, below the $(( FLOOR_MB / 1024 )) GB floor"
  elif (( BEFORE - NOW > DROP_MB )); then WHY="free space on $DISK fell by $(( (BEFORE - NOW) / 1024 )) GB, more than the $(( DROP_MB / 1024 )) GB a run may use"
  fi
  [[ -n $WHY ]] && break
  sleep 1
done

if [[ -n $WHY ]]; then
  echo "test.sh: stopping the whole run: $WHY." >&2
  stop TERM
  sleep 2
  stop KILL
  exit 99       # never `wait` here: a stuck process mustn't keep this running
fi
wait $PID
exit $?
