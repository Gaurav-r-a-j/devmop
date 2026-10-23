#!/bin/zsh
# Packages build/DevMop.app into build/DevMop-$VERSION.dmg with an Applications shortcut.
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${VERSION:-1.0.0}"
APP="build/DevMop.app"
DMG="build/DevMop-$VERSION.dmg"
STAGING="build/dmg"

[[ -d "$APP" ]] || { echo "Missing $APP, run make app first"; exit 1; }

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "DevMop $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

echo "Built $DMG"
