#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ICON="$APP_DIR/resources/AppIcon.icon"
ICTOOL="/Applications/Icon Composer.app/Contents/Executables/ictool"

python3 "$APP_DIR/scripts/generate-app-icon.py"

[ -f "$ICON/icon.json" ] || { echo "error: missing $ICON/icon.json" >&2; exit 1; }

if [ -x "$ICTOOL" ]; then
    mkdir -p "$APP_DIR/build"
    "$ICTOOL" "$ICON" --export-image --output-file "$APP_DIR/build/icon-light.png" \
        --platform macOS --rendition Default --width 1024 --height 1024 --scale 1
    "$ICTOOL" "$ICON" --export-image --output-file "$APP_DIR/build/icon-dark.png" \
        --platform macOS --rendition Dark --width 1024 --height 1024 --scale 1
fi
