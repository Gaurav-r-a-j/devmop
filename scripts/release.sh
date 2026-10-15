#!/bin/zsh
# Builds a signed, notarized DevSweep DMG ready to publish (setup steps in README › Releasing).
set -euo pipefail

cd "$(dirname "$0")/.."
: "${SIGN_IDENTITY:?Set SIGN_IDENTITY to your Developer ID Application identity}"
: "${VERSION:?Set VERSION, for example VERSION=1.0.0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-devsweep-notary}"

swift test
./scripts/build-app.sh

APP="build/DevSweep.app"
DMG="build/DevSweep-$VERSION.dmg"
STAGING="build/dmg"
APP_ZIP="build/DevSweep-$VERSION-app.zip"

codesign --verify --strict --deep "$APP"
codesign -dv "$APP" 2>&1 | grep -q "(runtime)" || { echo "Hardened runtime is missing"; exit 1; }

# Notarize and staple the app itself, so a copy outside the DMG also opens offline.
ditto -c -k --keepParent "$APP" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"
rm -f "$APP_ZIP"

DSYM="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/DevSweep.dSYM"
[[ -d "$DSYM" ]] && ditto -c -k --keepParent "$DSYM" "build/DevSweep-$VERSION.dSYM.zip"

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "DevSweep $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

shasum -a 256 "$DMG"
echo "Ready to publish: $DMG"
