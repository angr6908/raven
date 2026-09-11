#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$(cd "$APP_DIR" && swift build -c release --show-bin-path)"
BUILD="$BIN_DIR/Raven"
BUNDLE="$APP_DIR/build/Raven.app"

[ -x "$BUILD" ] || { echo "error: run 'swift build -c release' first" >&2; exit 1; }

if command -v magick >/dev/null && command -v rsvg-convert >/dev/null; then
    "$APP_DIR/scripts/make-icon.sh"
fi

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

cp "$BUILD" "$BUNDLE/Contents/MacOS/Raven"
cp "$APP_DIR/resources/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Raven</string>
    <key>CFBundleDisplayName</key>
    <string>Raven</string>
    <key>CFBundleIdentifier</key>
    <string>com.raven.launcher</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleExecutable</key>
    <string>Raven</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>27.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$BUNDLE"

echo "Built $BUNDLE"
