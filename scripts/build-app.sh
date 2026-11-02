#!/bin/zsh
# Builds a universal .app with Command Line Tools only. No Xcode needed.
#   scripts/build-app.sh                           ad-hoc signed, for this Mac and friendly testers
#   SIGN_ID="Developer ID Application: …" scripts/build-app.sh    signed with hardened runtime, ready to notarise
set -e
cd "${0:A:h}/.."
NAME=$(sed -n 's/.*static let name = "\(.*\)"/\1/p' Sources/IngestCore/AppInfo.swift | head -1)
ID=$(sed -n 's/.*static let bundleID = "\(.*\)"/\1/p' Sources/IngestCore/AppInfo.swift | head -1)
VERSION=$(sed -n 's/.*static let version = "\(.*\)"/\1/p' Sources/IngestCore/AppInfo.swift | head -1)
OUT=dist/$NAME.app
for arch in arm64 x86_64; do
  swift build -c release --product IngestApp --triple $arch-apple-macosx14.0 --scratch-path .build/$arch 2>&1 | tail -1
done
rm -rf "$OUT"; mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
bin() { swift build -c release --product IngestApp --triple $1-apple-macosx14.0 --scratch-path .build/$1 --show-bin-path; }
lipo -create "$(bin arm64)/IngestApp" "$(bin x86_64)/IngestApp" -output "$OUT/Contents/MacOS/$NAME"
sed -e "s/__NAME__/$NAME/g" -e "s/__ID__/$ID/g" -e "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$OUT/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$OUT/Contents/Resources/"
if [ -n "$SIGN_ID" ]; then
  codesign -f --options runtime --timestamp -s "$SIGN_ID" "$OUT"
else
  codesign -f -s - "$OUT"
fi
codesign --verify --strict "$OUT"
echo "$OUT  $(lipo -archs "$OUT/Contents/MacOS/$NAME")  $(du -sh "$OUT" | cut -f1)"
