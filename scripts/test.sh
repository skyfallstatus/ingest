#!/bin/zsh
# Runs the tests with Command Line Tools only. No Xcode needed.
#
# Some tests really do fill a disk image, and a test that lost its image once filled the Mac's own disk instead. So a run looks
# after the disk it's on, and the Mac it's on. It won't start below 150 GB free. A watchdog stops the whole run, and says why, if:
#   free space falls by more than 40 GB or below 100 GB, or can't be read   exit 99
#   the run takes more than 20 minutes                                      exit 98
#   a new process can't be started, even once                               exit 97
# Only one run goes at a time, and its scratch goes with it, however it ends. scripts/test-watchdog.pl does the watching.
#
# A smaller disk or a slower Mac can ask for something else, knowing what these are for:
#   INGEST_TEST_START_MB=60000 INGEST_TEST_FLOOR_MB=30000 INGEST_TEST_MINUTES=40 scripts/test.sh
START_MB=${INGEST_TEST_START_MB:-153600}
FLOOR_MB=${INGEST_TEST_FLOOR_MB:-102400}
DROP_MB=${INGEST_TEST_DROP_MB:-40960}
LIMIT=$(( ${INGEST_TEST_MINUTES:-20} * 60 ))
[[ -n $INGEST_TEST_SECONDS ]] && LIMIT=$INGEST_TEST_SECONDS
SPAWN=${INGEST_TEST_SPAWN:-/usr/bin/true}     # the small process that has to start every second
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
export TMPDIR="$RUN/" INGEST_TEST_SCRATCH=$RUN

F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
export WATCH_BEFORE=$BEFORE WATCH_FLOOR=$FLOOR_MB WATCH_DROP=$DROP_MB WATCH_LIMIT=$LIMIT WATCH_SPAWN=$SPAWN WATCH_DISK=$DISK WATCH_RUN=$RUN WATCH_LOCK=$LOCK
exec /usr/bin/perl "${0:A:h}/test-watchdog.pl" swift test -j $JOBS --no-parallel "$@" --disable-xctest -Xswiftc -F$F -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing -Xlinker -F$F -Xlinker -rpath -Xlinker $F -Xlinker -rpath -Xlinker $L
