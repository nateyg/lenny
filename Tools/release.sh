#!/bin/bash
# Builds, signs, notarizes and staples a distributable Lenny.dmg.
#
#     Tools/release.sh
#
# One-time setup, both of which only you can do:
#
#   1. Create a Developer ID Application certificate.
#      Xcode → Settings → Accounts → Manage Certificates → + → Developer ID
#      Application. (Needs a paid membership; an "Apple Development" cert is for
#      running locally and cannot be notarized.)
#
#   2. Store notary credentials in the keychain:
#      xcrun notarytool store-credentials "lenny-notary" \
#          --apple-id "you@example.com" --team-id "ABCDE12345" \
#          --password "<app-specific password from appleid.apple.com>"
#
# Notarization is an automated malware scan, not App Review — nobody reads it,
# and it usually returns in a couple of minutes. Without it, macOS refuses to
# open the download and buries the override in System Settings.

set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-lenny-notary}"
BUILD="build/release"
APP="$BUILD/Build/Products/Release/Lenny.app"
DMG="dist/Lenny.dmg"

IDENTITY=$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)

if [ -z "$IDENTITY" ]; then
    echo "No 'Developer ID Application' certificate in the keychain."
    echo "Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application"
    echo
    echo "Signing identities currently available:"
    security find-identity -v -p codesigning | grep '"' || echo "  (none)"
    echo "An 'Apple Development' cert is for local runs and cannot be notarized."
    exit 1
fi
echo "==> Signing as: $IDENTITY"

echo "==> Building Release"
rm -rf "$BUILD" dist
xcodebuild -project Lenny.xcodeproj -scheme Lenny -configuration Release \
    -derivedDataPath "$BUILD" CODE_SIGNING_ALLOWED=NO build > /dev/null

echo "==> Signing"
# Hardened runtime is required for notarization and is already on in the target.
codesign --force --deep --options runtime --timestamp \
    --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Building DMG"
mkdir -p dist staging
cp -R "$APP" staging/
ln -s /Applications staging/Applications
hdiutil create -volname Lenny -srcfolder staging -ov -format UDZO "$DMG" > /dev/null
rm -rf staging
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

echo "==> Notarizing (a couple of minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

echo "==> Stapling"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo
echo "Ready: $DMG"
echo "Verify a download opens cleanly:  spctl -a -t open --context context:primary-signature -v $DMG"
