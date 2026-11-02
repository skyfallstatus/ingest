#!/bin/zsh
# Builds a release, signs it, writes the update feed and uploads them to GitHub Releases. Only ever run by hand.
# The one file people download is the disk image, and it's the same file updates come from.
#   scripts/release.sh --dry-run     everything but the upload
#   scripts/release.sh               the same, then asks before it uploads
# The private signing key is in the login Keychain and nowhere else. The feed goes where `AppInfo.feedURL` looks.
#
# A mistake here reaches every tester and can't be fixed by an update, and most of them fail without a word: a wrong key, or a build
# number that isn't higher, is simply ignored by every Mac. So this refuses them, and looks at GitHub, read-only, only on a real run.
set -e -o pipefail
cd "${0:A:h}/.."
unset EXTRA_SWIFT_FLAGS         # a test build's flags must never reach a public one
refuse() { echo "$1" >&2; exit 1 }
TOOLS=.build/arm64/artifacts/sparkle/Sparkle/bin
DRY=0; [[ "$1" == "--dry-run" ]] && DRY=1
REPO_URL=$(sed -n 's/.*static let repoURL = "\(.*\)"/\1/p' Sources/IngestCore/AppInfo.swift | head -1)
REPO=${REPO_URL#https://github.com/}
NAME=$(sed -n 's/.*static let name = "\(.*\)"/\1/p' Sources/IngestCore/AppInfo.swift | head -1)
VERSION=$(sed -n 's/.*static let version = "\(.*\)"/\1/p' Sources/IngestCore/AppInfo.swift | head -1)
TAG=v$VERSION
[[ -z $(git status --porcelain) ]] || refuse "The tree has changes in it. A release is built from a commit."
COMMIT=$(git rev-parse HEAD)
if (( ! DRY )); then
  gh api repos/$REPO/commits/$COMMIT --silent 2>/dev/null || refuse "GitHub doesn't have $COMMIT, or can't be reached. Push it first."
  if gh release view $TAG --repo $REPO >/dev/null 2>&1; then refuse "$TAG is already released. Raise the version in AppInfo.swift."; fi
fi

scripts/build-app.sh
PLIST=dist/$NAME.app/Contents/Info.plist
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' $PLIST)

# Every Mac checks an update against the key in the app it already has, so a release signed with another key reaches nobody.
KEYCHAIN=$($TOOLS/generate_keys -p 2>/dev/null) || refuse "There's no signing key in this Mac's Keychain."
[[ $KEYCHAIN == $(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' $PLIST) ]] || refuse "The Keychain's signing key isn't the one in the app. Every Mac would refuse this release, and say nothing."

# Sparkle goes by the build number, the count of commits, so a rewritten history or a shallow clone can lower it.
if (( ! DRY )); then
  RELEASES=$(gh release list --repo $REPO --limit 1 --json tagName --jq length) || refuse "Can't see this repo's releases, so can't check the build number."
  if (( RELEASES > 0 )); then
    PUBLISHED=$(gh release download --repo $REPO --pattern appcast.xml --output - | sed -n 's/.*<sparkle:version>\([0-9]*\)<.*/\1/p' | sort -n | tail -1) || refuse "Can't read the published feed, so can't check the build number."
    [[ -n $PUBLISHED ]] || refuse "The published feed has no build number in it."
    (( BUILD > PUBLISHED )) || refuse "This is build $BUILD and the published feed is at $PUBLISHED. Every Mac would ignore it, and say nothing."
  fi
fi

scripts/build-dmg.sh
DMG=$NAME.dmg
SIGNATURE=$($TOOLS/sign_update dist/$DMG)
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
$TOOLS/sign_update dist/appcast.xml        # the app refuses a feed that isn't signed. This writes the signature into the file
$TOOLS/sign_update --verify dist/appcast.xml
echo "dist/$DMG and dist/appcast.xml are ready for $TAG."
(( DRY )) && exit 0
read "ANSWER?Upload $TAG to $REPO for everyone with the app? Type yes: "
[[ $ANSWER == yes ]] || { echo "Nothing uploaded."; exit 1; }
[[ $(git rev-parse HEAD) == $COMMIT && -z $(git status --porcelain) ]] || refuse "The tree moved while this was building. Nothing uploaded."
gh release create $TAG dist/$DMG dist/appcast.xml --repo $REPO --target $COMMIT --title "$NAME $VERSION" --notes "$NAME $VERSION"
