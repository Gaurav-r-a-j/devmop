#!/bin/zsh
# Builds a signed, notarized DevMop DMG ready to publish (setup steps in README › Releasing).
set -euo pipefail

cd "$(dirname "$0")/.."
: "${SIGN_IDENTITY:?Set SIGN_IDENTITY to your Developer ID Application identity}"
: "${VERSION:?Set VERSION, for example VERSION=1.0.0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-devmop-notary}"

swift test
./scripts/build-app.sh

APP="build/DevMop.app"
DMG="build/DevMop-$VERSION.dmg"
APP_ZIP="build/DevMop-$VERSION-app.zip"

codesign --verify --strict --deep "$APP"
codesign -dv "$APP" 2>&1 | grep -q "(runtime)" || { echo "Hardened runtime is missing"; exit 1; }

# Notarize and staple the app itself, so a copy outside the DMG also opens offline.
ditto -c -k --keepParent "$APP" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"
rm -f "$APP_ZIP"

DSYM="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/DevMop.dSYM"
[[ -d "$DSYM" ]] && ditto -c -k --keepParent "$DSYM" "build/DevMop-$VERSION.dSYM.zip"

VERSION="$VERSION" ./scripts/dmg.sh
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

shasum -a 256 "$DMG"
echo "Ready to publish: $DMG"
