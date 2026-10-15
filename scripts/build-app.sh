#!/bin/zsh
# Builds build/DevSweep.app (universal) and the sweep CLI.
# Set SIGN_IDENTITY="Developer ID Application: …" to sign for distribution; ad-hoc signing otherwise.
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP="build/DevSweep.app"

swift build -c release --arch arm64 --arch x86_64 --product DevSweep
swift build -c release --arch arm64 --arch x86_64 --product sweep
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/DevSweep" "$APP/Contents/MacOS/DevSweep"
cp "$BIN/sweep" "build/sweep"

ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DevSweep</string>
    <key>CFBundleDisplayName</key><string>DevSweep</string>
    <key>CFBundleIdentifier</key><string>app.devsweep.DevSweep</string>
    <key>CFBundleExecutable</key><string>DevSweep</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 DevSweep</string>
</dict>
</plist>
PLIST

LOCAL_IDENTITY="$(security find-identity -p codesigning 2>/dev/null | awk '/"DevSweep Local Signing"/ { print $2; exit }')"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "build/sweep"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
elif [[ -n "$LOCAL_IDENTITY" ]] && codesign --force --sign "$LOCAL_IDENTITY" "build/sweep" 2>/dev/null; then
    # A stable identity keeps Full Disk Access granted across rebuilds.
    codesign --force --sign "$LOCAL_IDENTITY" "$APP"
elif [[ -n "$LOCAL_IDENTITY" ]]; then
    echo "Note: macOS blocked access to the DevSweep Local Signing key. Run this script once in Terminal and choose Always Allow."
    codesign --force --sign - "build/sweep"
    codesign --force --sign - "$APP"
else
    echo "Note: run scripts/make-signing-identity.sh once so permissions survive rebuilds."
    codesign --force --sign - "build/sweep"
    codesign --force --sign - "$APP"
fi

echo "Built $APP and build/sweep (version $VERSION, build $BUILD_NUMBER)"
