#!/bin/zsh
# Builds the install disk image from dist/<Name>.app: app left, Applications right, on the static background.
# No Finder, no AppleScript, nothing that asks for permission: scripts/dmg-layout.py writes the window's .DS_Store directly.
# Only this run's own image is attached, at a private mount point, and detached again.
set -e -o pipefail
cd "${0:A:h}/.."
NAME=$(sed -n 's/.*static let name = "\(.*\)"/\1/p' Sources/IngestCore/AppInfo.swift | head -1)
APP="dist/$NAME.app"
OUT="dist/$NAME.dmg"
[ -d "$APP" ] || { echo "Build the app first: scripts/build-app.sh" >&2; exit 1; }
codesign --verify --strict "$APP" || { echo "$APP isn't properly signed. Build it again: scripts/build-app.sh" >&2; exit 1; }
NEWER=$(find Sources Resources Package.swift -type f -newer "$APP/Contents/MacOS/$NAME" -print -quit)
[ -z "$NEWER" ] || { echo "$APP is older than $NEWER, so this image would ship the wrong build. Run scripts/build-app.sh first." >&2; exit 1; }
W=$(mktemp -d /tmp/ingest-dmg.XXXXXX)
MOUNT=""
detach() {
  [ -n "$MOUNT" ] && hdiutil detach -quiet "$MOUNT" 2>/dev/null || true
  rm -f "$W/rw.dmg"
}
trap detach EXIT

mkdir -p "$W/stage/.background" "$W/mnt"
ditto "$APP" "$W/stage/$NAME.app"
ln -s /Applications "$W/stage/Applications"
cp Resources/dmg/background.tiff "$W/stage/.background/background.tiff"
SIZE=$(( $(du -sm "$W/stage" | cut -f1) + 24 ))
hdiutil create -quiet -srcfolder "$W/stage" -volname "$NAME" -fs HFS+ -format UDRW -size ${SIZE}m "$W/rw.dmg"
MOUNT=$(hdiutil attach -nobrowse -noautoopen -noverify -mountrandom "$W/mnt" "$W/rw.dmg" | awk -F'\t' '/\/mnt\// { print $NF }' | tail -1)
[ -n "$MOUNT" ] || { echo "The image didn't mount." >&2; exit 1; }
python3 -I scripts/dmg-layout.py "$MOUNT" "$NAME" "$NAME.app"
sync
hdiutil detach -quiet "$MOUNT"
MOUNT=""
hdiutil convert -quiet "$W/rw.dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$OUT"
hdiutil verify -quiet "$OUT"
echo "$OUT  $(du -sh "$OUT" | cut -f1)"
