#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d /tmp/raven-icon.XXXXXX)"
SVG="$APP_DIR/resources/RavenLogo.svg"
ICONSET="$WORK/raven.iconset"

mkdir "$ICONSET"
magick -size 1024x1024 gradient:'#111827-#3730a3' "$WORK/background.png"
magick -size 1024x1024 xc:none -fill white \
    -draw 'roundrectangle 96,96 927,927 185,185' "$WORK/mask.png"
magick "$WORK/background.png" "$WORK/mask.png" -alpha off \
    -compose CopyOpacity -composite "$WORK/rounded.png"
rsvg-convert -w 560 -h 560 "$SVG" -o "$WORK/logo.png"
magick "$WORK/rounded.png" "$WORK/logo.png" -gravity center \
    -composite "$WORK/icon-1024.png"

magick "$WORK/icon-1024.png" -resize 16x16 "$ICONSET/icon_16x16.png"
magick "$WORK/icon-1024.png" -resize 32x32 "$ICONSET/icon_16x16@2x.png"
magick "$WORK/icon-1024.png" -resize 32x32 "$ICONSET/icon_32x32.png"
magick "$WORK/icon-1024.png" -resize 64x64 "$ICONSET/icon_32x32@2x.png"
magick "$WORK/icon-1024.png" -resize 128x128 "$ICONSET/icon_128x128.png"
magick "$WORK/icon-1024.png" -resize 256x256 "$ICONSET/icon_128x128@2x.png"
magick "$WORK/icon-1024.png" -resize 256x256 "$ICONSET/icon_256x256.png"
magick "$WORK/icon-1024.png" -resize 512x512 "$ICONSET/icon_256x256@2x.png"
magick "$WORK/icon-1024.png" -resize 512x512 "$ICONSET/icon_512x512.png"
magick "$WORK/icon-1024.png" -resize 1024x1024 "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$APP_DIR/resources/AppIcon.icns"
