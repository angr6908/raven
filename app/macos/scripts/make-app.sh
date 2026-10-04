#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$(cd "$APP_DIR" && swift build -c release --show-bin-path)"
BUILD="$BIN_DIR/Raven"
BUNDLE="$APP_DIR/build/Raven.app"
PARTIAL="$APP_DIR/build/icon-partial.plist"
ACTOOL="/Applications/Xcode.app/Contents/Developer/usr/bin/actool"
ICON="$APP_DIR/resources/AppIcon.icon"

if [ -z "${CORE_BIN:-}" ]; then
    CORE_DIR="$(cd "$APP_DIR/../../core" && pwd)"
    (cd "$CORE_DIR" && cargo build --release)
    CORE_BIN="$CORE_DIR/target/release/raven"
fi
[ -x "$CORE_BIN" ] || { echo "error: core binary not found at $CORE_BIN" >&2; exit 1; }

[ -x "$BUILD" ] || { echo "error: run 'swift build -c release' first" >&2; exit 1; }
[ -x "$ACTOOL" ] || { echo "error: Xcode actool is required" >&2; exit 1; }

"$APP_DIR/scripts/make-icon.sh"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

cp "$BUILD" "$BUNDLE/Contents/MacOS/Raven"
cp "$CORE_BIN" "$BUNDLE/Contents/Resources/raven"
cp -R "$APP_DIR/resources/Logos" "$BUNDLE/Contents/Resources/Logos"
cp "$APP_DIR/resources/RavenLogo.svg" "$BUNDLE/Contents/Resources/RavenLogo.svg"

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    "$ACTOOL" "$ICON" \
    --compile "$BUNDLE/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 27.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$PARTIAL"

python3 - <<PY
import plistlib
from pathlib import Path
info = {
    "CFBundleName": "Raven",
    "CFBundleDisplayName": "Raven",
    "CFBundleIdentifier": "com.raven.launcher",
    "CFBundleVersion": "3",
    "CFBundleShortVersionString": "3.0",
    "CFBundlePackageType": "APPL",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleExecutable": "Raven",
    "LSMinimumSystemVersion": "27.0",
    "LSApplicationCategoryType": "public.app-category.developer-tools",
    "NSPrincipalClass": "NSApplication",
}
partial_path = Path("$PARTIAL")
if partial_path.exists():
    with partial_path.open("rb") as handle:
        info.update(plistlib.load(handle))
info.setdefault("CFBundleIconName", "AppIcon")
info.setdefault("CFBundleIconFile", "AppIcon")
dest = Path("$BUNDLE/Contents/Info.plist")
with dest.open("wb") as handle:
    plistlib.dump(info, handle)
PY

codesign --force --sign - "$BUNDLE/Contents/Resources/raven"
codesign --force --sign - "$BUNDLE"
echo "Built $BUNDLE"
