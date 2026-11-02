#!/bin/zsh
# A real update, end to end, on this Mac only: a build of a lower version updates itself to a higher one through real Sparkle
# from a local server, relaunches and keeps its settings. A tampered update and an unsigned feed are refused, a job in progress holds
# the install, and Keep Copying at a restart leaves Restart to press again.
# It uses a throwaway bundle ID and a throwaway signing key, reads no volume, and takes everything it made away with it.
set -o pipefail
R=${0:A:h:h}
W=$(mktemp -d /private/tmp/ingest-update.XXXXXX)
ID=com.skyfallstatus.ingest.updatetest
FREE=$(df -g /private/tmp | awk 'NR==2 { print $4 }')
(( FREE >= 150 )) || { echo "Only $FREE GB free. Not starting."; rm -rf $W; exit 1 }
PASS=0; FAIL=0
SERVER=""
cleanup() {
  pkill -f "$W/app/Ingest.app" 2>/dev/null
  [[ -n $SERVER ]] && kill $SERVER 2>/dev/null
  for dev in $(hdiutil info | awk -v id=$ID '/^image-path/ { mine = index($0, id) > 0 } mine && /^\/dev\/disk[0-9]+\t/ { print $1 }'); do hdiutil detach -quiet -force $dev; done
  defaults delete $ID 2>/dev/null
  rm -rf ~/Library/Caches/$ID ~/Library/HTTPStorages/$ID ~/Library/Preferences/$ID.plist "$HOME/Library/Application Support/$ID"
  [[ -d $W/src ]] && /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u $W/app/Ingest.app 2>/dev/null
  rm -rf $W
}
trap cleanup EXIT
say_() { print -r -- "$*" }
check() { if eval "$2"; then say_ "ok    $1"; (( PASS++ )); else say_ "FAIL  $1"; (( FAIL++ )); fi }
wait_for() { local n=0; until grep -q "$1" $W/log 2>/dev/null; do sleep 1; (( ++n > $2 )) && return 1; done; return 0 }

git clone -q $R $W/src || exit 1
( cd $W/src && EXTRA_SWIFT_FLAGS="-Xswiftc -DUPDATE_TEST" zsh scripts/build-app.sh ) || exit 1
TOOLS=$W/src/.build/arm64/artifacts/sparkle/Sparkle/bin

cat > $W/key.swift <<'SWIFT'
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString())
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
KEYS=("${(@f)$(swift $W/key.swift)}")
print -r -- $KEYS[1] > $W/private.key
PUBLIC=$KEYS[2]

mkdir -p $W/site $W/support $W/app $W/card/CLIP $W/drive
dd if=/dev/urandom of=$W/card/CLIP/big.bin bs=1m count=600 2>/dev/null
PORT=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')

variant() {   # app, short version, build number
  local p=$1/Contents/Info.plist
  ditto $W/src/dist/Ingest.app $1
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" -c "Set :CFBundleShortVersionString $2" -c "Set :CFBundleVersion $3" \
    -c "Set :SUFeedURL http://127.0.0.1:$PORT/appcast.xml" -c "Set :SUPublicEDKey $PUBLIC" \
    -c "Add :LSEnvironment dict" -c "Add :LSEnvironment:INGEST_ONLY_VOLUMES string none-of-these" -c "Add :LSEnvironment:INGEST_SUPPORT_DIR string $W/support" \
    -c "Add :LSEnvironment:INGEST_UPDATE_LOG string $W/log" -c "Add :LSEnvironment:INGEST_UPDATE_MODE string $4" \
    -c "Add :LSEnvironment:INGEST_UPDATE_CARD string $W/card" -c "Add :LSEnvironment:INGEST_UPDATE_DRIVE string $W/drive" $p
  codesign -f -s - $1
}
package() {   # the same kind of file a release publishes
  rm -f $W/site/Ingest.dmg
  ln -sfh /Applications $W/new/Applications
  hdiutil create -quiet -volname Ingest -srcfolder $W/new -format UDZO $W/site/Ingest.dmg
}
publish() {   # the image's bytes as signed, then as served
  local sig=$($TOOLS/sign_update --ed-key-file $W/private.key $W/site/Ingest.dmg)
  cat > $W/site/appcast.xml <<FEED
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Ingest</title><item><title>Ingest 0.2</title>
<sparkle:version>200</sparkle:version><sparkle:shortVersionString>0.2</sparkle:shortVersionString><sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
<enclosure url="http://127.0.0.1:$PORT/Ingest.dmg" type="application/octet-stream" $sig/></item></channel></rss>
FEED
}
sign_feed() { $TOOLS/sign_update --ed-key-file $W/private.key $W/site/appcast.xml }
start() {     # mode
  pkill -f "$W/app/Ingest.app" 2>/dev/null; sleep 1
  rm -rf $W/app/Ingest.app $W/log ~/Library/Caches/$ID
  variant $W/app/Ingest.app 0.1 100 $1
  open -g -n $W/app/Ingest.app
}
version() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' $W/app/Ingest.app/Contents/Info.plist }
running() { pgrep -f "$W/app/Ingest.app/Contents/MacOS/Ingest" | head -1 }

variant $W/new/Ingest.app 0.2 200 plain
package
publish
sign_feed
python3 -I -m http.server $PORT --bind 127.0.0.1 --directory $W/site >/dev/null 2>&1 &
SERVER=$!
sleep 1
defaults write $ID opensOnCardIn -bool false
defaults write $ID sawFirstRun -bool true       # no setup page on anyone's screen

say_ "--- a plain update"
start plain
check "the old build launched" 'wait_for "^0.1 .* launched" 30'
OLD=$(running)
check "it got to ready, with nothing shown" 'wait_for "ready: Ingest 0.2 is ready" 60'
check "the new version is running" 'wait_for "^0.2 .* launched" 60'
check "on disk it's 0.2, in the same place" '[[ $(version) == 0.2 ]]'
check "it's a new process" '[[ -n $(running) && $(running) != $OLD ]]'
check "settings kept" 'grep "^0.2 .* launched" $W/log | grep -q "opensOnCardIn=false"'

attached() { hdiutil info | grep '^image-path' | grep -c $ID }
pkill -f "$W/app/Ingest.app" 2>/dev/null; sleep 1
check "a finished update leaves no image attached" '[[ $(attached) == 0 ]]'
say_ "      attached: $(attached)"

say_ "--- a well-formed update with the wrong contents"
touch $W/new/extra-file             # the image is valid, and these aren't the bytes that were signed
package
rm -f $W/new/extra-file
start plain
check "the old build launched" 'wait_for "^0.1 .* launched" 30'
check "it found the update" 'wait_for "found 0.2" 60'
check "it was fetched, then given up on" 'wait_for "downloaded" 60 && wait_for "dismissed\|error:" 60'
sleep 2
check "it never got as far as ready" '! grep -q "ready:" $W/log'
check "the signature is what stopped it" 'grep -qi "sign" $W/log'
say_ "      $(grep -E "error:" $W/log | head -1 | cut -c1-110)"
check "the old version is still on disk" '[[ $(version) == 0.1 ]]'
check "and still running" '[[ -n $(running) ]]'
check "nothing restarted" '! grep -q "restarting" $W/log'
package
publish

say_ "--- a feed that isn't signed"
start plain
check "the old build launched" 'wait_for "^0.1 .* launched" 30'
check "it was refused" 'wait_for "error:" 60'
say_ "      $(grep -E "error:" $W/log | head -1 | cut -c1-110)"
check "it never saw the update" '! grep -q "found 0.2" $W/log'
check "the old version is still on disk" '[[ $(version) == 0.1 ]]'
sign_feed

say_ "--- a job in progress"
rm -rf $W/drive; mkdir $W/drive
start job
check "the update was ready first" 'wait_for "ready: Ingest 0.2 is ready" 60'
check "the job started" 'wait_for "job running" 60'
check "Restart was refused during it" 'wait_for "refused during a job on CARD" 30'
check "and said why" 'grep -q "It can restart once CARD is done" $W/log'
check "the job ended" 'wait_for "the job is done" 180'
check "it only restarted after that" 'wait_for "^0.2 .* launched" 180'
check "in that order" '[[ $(grep -n "refused during" $W/log | cut -d: -f1) -lt $(grep -n "the job is done" $W/log | cut -d: -f1) && $(grep -n "the job is done" $W/log | cut -d: -f1) -lt $(grep -n "^0.2 " $W/log | head -1 | cut -d: -f1) ]]'
say_ "      $(grep 'refused during' $W/log | cut -c1-110)"
check "the copy finished" 'cmp -s $W/card/CLIP/big.bin $W/drive/S/CLIP/big.bin'

say_ "--- Keep Copying at a restart"
start keepCopying
check "the old build launched" 'wait_for "^0.1 .* launched" 30'
check "it went back to ready, with Restart to press" 'wait_for "kept copying: Ingest 0.2 is ready" 60'
check "and pressing it again restarted the app" 'wait_for "^0.2 .* launched" 60'
check "on disk it's 0.2" '[[ $(version) == 0.2 ]]'

pkill -f "$W/app/Ingest.app" 2>/dev/null; sleep 1
say_ "      attached at the end: $(attached)"
say_ "passed $PASS, failed $FAIL"
(( FAIL == 0 ))
