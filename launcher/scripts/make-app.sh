#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$APP_DIR/.build/release/Raven"
BUNDLE="$APP_DIR/build/Raven.app"

[ -x "$BUILD" ] || { echo "error: run 'swift build -c release' first" >&2; exit 1; }

"$APP_DIR/scripts/make-icon.sh"

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
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>Raven</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIconFiles</key>
    <array>
        <string>AppIcon</string>
        <string>AppIcon.icns</string>
    </array>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
</dict>
</plist>
PLIST

codesign --force --sign - "$BUNDLE" 2>/dev/null || true

echo "Built $BUNDLE"
