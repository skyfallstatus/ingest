#!/bin/zsh
# Requires a paid Developer ID. Run after: SIGN_ID="Developer ID Application: …" scripts/build-app.sh
#   xcrun notarytool store-credentials ingest --apple-id … --team-id … --password <app-specific>
#   scripts/notarize.sh ingest
set -e
cd "${0:A:h}/.."
APP=$(ls -d dist/*.app | head -1)
ditto -c -k --keepParent "$APP" dist/notarize.zip
xcrun notarytool submit dist/notarize.zip --keychain-profile "${1:?keychain profile name}" --wait
xcrun stapler staple "$APP"
ditto -c -k --keepParent "$APP" "dist/$(basename "$APP" .app).zip"
rm dist/notarize.zip
spctl -a -vv -t exec "$APP"
