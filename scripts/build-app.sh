#!/bin/zsh
# Builds a universal .app with Command Line Tools only. No Xcode needed.
#   scripts/build-app.sh                           ad-hoc signed, for this Mac and friendly testers
#   SIGN_ID="Developer ID Application: …" scripts/build-app.sh    signed with hardened runtime, ready to notarise
set -e -o pipefail
cd "${0:A:h}/.."
NAME=$(sed -n 's/.*static let name = "\(.*\)"/\1/p' Sources/IngestCore/AppInfo.swift | head -1)
ID=$(sed -n 's/.*static let bundleID = "\(.*\)"/\1/p' Sources/IngestCore/AppInfo.swift | head -1)
VERSION=$(sed -n 's/.*static let version = "\(.*\)"/\1/p' Sources/IngestCore/AppInfo.swift | head -1)
OUT=dist/$NAME.app
# A failed compile has to stop here. Otherwise last time's binaries get packaged as this build.
for arch in arm64 x86_64; do
  swift build -j 6 -c release --product IngestApp --triple $arch-apple-macosx14.0 --scratch-path .build/$arch ${=EXTRA_SWIFT_FLAGS} 2>&1 | tail -1
done
bin() { swift build -c release --product IngestApp --triple $1-apple-macosx14.0 --scratch-path .build/$1 ${=EXTRA_SWIFT_FLAGS} --show-bin-path; }
ARM=$(bin arm64)
INTEL=$(bin x86_64)
rm -rf "$OUT"; mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources" "$OUT/Contents/Frameworks"
lipo -create "$ARM/IngestApp" "$INTEL/IngestApp" -output "$OUT/Contents/MacOS/$NAME"
# Sparkle lives inside the app. It isn't sandboxed, so the framework's XPC services aren't needed.
SPARKLE="$OUT/Contents/Frameworks/Sparkle.framework"
ditto "$ARM/Sparkle.framework" "$SPARKLE"
rm -rf "$SPARKLE/Versions/B/XPCServices" "$SPARKLE/XPCServices"
install_name_tool -add_rpath @executable_path/../Frameworks "$OUT/Contents/MacOS/$NAME"
FEED=$(sed -n 's/.*static let repoURL = "\(.*\)"/\1/p' Sources/IngestCore/AppInfo.swift | head -1)/releases/latest/download/appcast.xml
# Every build says which one it is, so a report can too. A tree with changes in it says so.
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 0)
COMMIT=$(git describe --always --dirty 2>/dev/null || echo unknown)
sed -e "s/__NAME__/$NAME/g" -e "s/__ID__/$ID/g" -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" -e "s/__COMMIT__/$COMMIT/g" -e "s#__FEED__#$FEED#g" Resources/Info.plist > "$OUT/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$OUT/Contents/Resources/"
# Inside out, because each signature covers what's inside it.
for inner in "$SPARKLE/Versions/B/Updater.app" "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE" "$OUT"; do
  if [ -n "$SIGN_ID" ]; then
    codesign -f --options runtime --timestamp -s "$SIGN_ID" "$inner"
  else
    codesign -f -s - "$inner"
  fi
done
codesign --verify --strict "$OUT"
echo "$OUT  $(lipo -archs "$OUT/Contents/MacOS/$NAME")  $(du -sh "$OUT" | cut -f1)"
