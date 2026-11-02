#!/bin/zsh
# Builds a release, signs it, writes the update feed and uploads them to GitHub Releases. Only ever run by hand.
# The one file people download is the disk image, and it's the same file updates come from.
#   scripts/release.sh --dry-run     everything but the upload
#   scripts/release.sh               the same, then asks before it uploads
# The private signing key is in the login Keychain and nowhere else. The feed goes where `AppInfo.feedURL` looks.
set -e -o pipefail
cd "${0:A:h}/.."
DRY=0; [[ "$1" == "--dry-run" ]] && DRY=1
REPO_URL=$(sed -n 's/.*static let repoURL = "\(.*\)"/\1/p' Sources/IngestCore/AppInfo.swift | head -1)
REPO=${REPO_URL#https://github.com/}
NAME=$(sed -n 's/.*static let name = "\(.*\)"/\1/p' Sources/IngestCore/AppInfo.swift | head -1)
VERSION=$(sed -n 's/.*static let version = "\(.*\)"/\1/p' Sources/IngestCore/AppInfo.swift | head -1)
TAG=v$VERSION
[[ -z $(git status --porcelain) ]] || { echo "The tree has changes in it. A release is built from a commit." >&2; exit 1; }
if (( ! DRY )) && gh release view $TAG --repo $REPO >/dev/null 2>&1; then echo "$TAG is already released. Raise the version in AppInfo.swift." >&2; exit 1; fi

scripts/build-app.sh
scripts/build-dmg.sh
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' dist/$NAME.app/Contents/Info.plist)
DMG=$NAME.dmg
SIGNATURE=$(.build/arm64/artifacts/sparkle/Sparkle/bin/sign_update dist/$DMG)
cat > dist/appcast.xml <<FEED
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$NAME</title>
    <item>
      <title>$NAME $VERSION</title>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="$REPO_URL/releases/download/$TAG/$DMG" type="application/octet-stream" $SIGNATURE/>
    </item>
  </channel>
</rss>
FEED
echo "dist/$DMG and dist/appcast.xml are ready for $TAG."
(( DRY )) && exit 0
read "ANSWER?Upload $TAG to $REPO for everyone with the app? Type yes: "
[[ $ANSWER == yes ]] || { echo "Nothing uploaded."; exit 1; }
gh release create $TAG dist/$DMG dist/appcast.xml --repo $REPO --title "$NAME $VERSION" --notes "$NAME $VERSION"
