#!/bin/zsh
# Full app flow against two exFAT disk images, on a real file system, with real Sony clips.
# SAMPLE_CARD is a Sony card folder, read only: SAMPLE_CARD=/path/to/card scripts/selftest.sh
# No other volume is touched. The names are unique to this run, a name already mounted stops it, INGEST_ONLY_VOLUMES
# fences the app in, and only this run's own images are detached. They mount in /Volumes because the app only looks there.
set -e
SAMPLE="${SAMPLE_CARD:?set SAMPLE_CARD to a Sony card folder}"
W=$(mktemp -d /tmp/ingest-selftest.XXXXXX)
RUN=${W##*.}
DRIVE="STD $RUN"; CARD="STC $RUN"; OTHER="STO $RUN"     # hdiutil refuses an exFAT label over 11 characters
D="/Volumes/$DRIVE"; C="/Volumes/$CARD"; O="/Volumes/$OTHER"
for v in "$D" "$C" "$O"; do
  [ ! -e "$v" ] || { echo "$v is already mounted. Nothing was touched." >&2; rm -rf "$W"; exit 1; }
done

# Device and mount point of whatever is attached from this run's folder. The app re-attaches the card
# during the test, so the device can change. It's found from the image file, never from a volume name.
attached() {
  hdiutil info | awk -F'\t' -v run="${W:t}/" '/^image-path/ { mine = index($0, run) > 0 } mine && /^\/dev\/disk/ { print $1 "\t" $3 }'
}
detach() {
  for dev in $(attached | cut -f1 | grep -E '^/dev/disk[0-9]+$'); do
    hdiutil detach -quiet "$dev" 2>/dev/null || hdiutil detach -quiet -force "$dev" 2>/dev/null || true
  done
  rm -f "$W/drive.dmg" "$W/card.dmg" "$W/other.dmg"
}
trap detach EXIT

hdiutil create -size 8g -fs ExFAT -volname "$DRIVE" $W/drive.dmg >/dev/null
hdiutil create -size 4g -fs ExFAT -volname "$CARD" $W/card.dmg >/dev/null
hdiutil create -size 64m -fs ExFAT -volname "$OTHER" $W/other.dmg >/dev/null
hdiutil attach -quiet $W/drive.dmg; hdiutil attach -quiet $W/card.dmg; hdiutil attach -quiet $W/other.dmg
for v in "$D" "$C" "$O"; do
  attached | cut -f2 | grep -qxF "$v" || { echo "$v didn't mount from this run's image. Stopping before anything is written." >&2; exit 1; }
done
# A drive of 34 shoots, 29 following one layout, 5 older with an extra Video folder.
i=0
for c in "Tidemark Rowing Club" "Lantern Bakery Co." "Northgate Studio" "Fennel Kitchen" "Ashby Rowing" "Corvid Records"; do
 for s in Launch Pool Training Portraits Studio "Team day"; do
  i=$((i+1)); [ $i -gt 34 ] && break
  dd=$(printf '%02d' $(( (i % 27) + 1 ))); mm=$(printf '%02d' $(( (i % 9) + 1 )))
  p="$D/2026/Paid work/$c/$dd.$mm.26 $s"
  mkdir -p "$p/Footage/FX3" "$p/Project"
  [ $((i % 2)) -eq 0 ] && mkdir -p "$p/Photo/RAW" "$p/Photo/Exports"
  dd if=/dev/zero of="$p/Footage/FX3/C0001.MP4" bs=1k count=4 2>/dev/null
  [ $i -le 5 ] && { mkdir -p "$p/Video/FX3"; dd if=/dev/zero of="$p/Video/FX3/C0002.MP4" bs=1k count=4 2>/dev/null; }
 done
done
# A real card: a few real clips with their real metadata.
mkdir -p "$C/M4ROOT/CLIP" "$C/M4ROOT/THMBNL" "$C/PRIVATE/DATABASE" "$C/SONY" "$C/AVF_INFO"
cp "$SAMPLE/M4ROOT/MEDIAPRO.XML" "$C/M4ROOT/"
for f in $(ls -Sr "$SAMPLE/M4ROOT/CLIP" | grep -E '\.MP4$' | grep -v '^\._' | head -6); do
  b=${f%.MP4}; cp "$SAMPLE/M4ROOT/CLIP/$f" "$SAMPLE/M4ROOT/CLIP/${b}M01.XML" "$C/M4ROOT/CLIP/"; cp "$SAMPLE/M4ROOT/THMBNL/${b}T01.JPG" "$C/M4ROOT/THMBNL/" 2>/dev/null || true
done
cp "$SAMPLE/PRIVATE/DATABASE/"* "$C/PRIVATE/DATABASE/" 2>/dev/null || true
: > "$C/SONY/SONYCARD.IND"
du -sh "$C" | cut -f1
# A volume it has to ask about: camera files, no camera folders. The app mounts it when the run gets there.
dd if=/dev/urandom of="$O/A001.braw" bs=1m count=4 2>/dev/null
hdiutil detach -quiet "$O"
cd "${0:A:h}/.."
swift build --product IngestApp
rc=0
INGEST_ALLOW_DISK_IMAGES=1 INGEST_ONLY_VOLUMES="$DRIVE:$CARD:$OTHER" INGEST_SUPPORT_DIR=$W/support INGEST_SELFTEST_CARD_IMAGE=$W/card.dmg \
  INGEST_SELFTEST_DRIVE_IMAGE=$W/drive.dmg INGEST_SELFTEST_OTHER_IMAGE=$W/other.dmg INGEST_SELFTEST_OTHER_NAME="$OTHER" \
  .build/debug/IngestApp --selftest "$DRIVE" "$CARD" $W/shots || rc=$?
echo "--- what's on the drive"
find "$D/2026/Paid work/Tidemark Rowing Club" -maxdepth 6 -not -name '._*' | sed "s|$D/2026/Paid work/||" | grep -E 'Regatta|19.10.26 Pool$' | head -14 || true
echo "shots in $W/shots"
exit $rc
