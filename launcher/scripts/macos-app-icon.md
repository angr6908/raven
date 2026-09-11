# Native macOS 27 App Icon

How to regenerate **this exact** Raven launcher icon from `RavenLogo.svg`
for macOS 27 (Tahoe / Liquid Glass).

Locked recipe: `scripts/generate-app-icon.py`. It writes `AppIcon.icon`
with the same canvas, scale, optical lift, and colors as the current app.
Then `scripts/make-icon.sh` exports light/dark previews, and
`scripts/make-app.sh` compiles the `.icon` into `Raven.app`.

Do not go back to a hand-rounded PNG + `.icns`. That path is what produced
the “square logo inside a square” icon and a bundle with no appearance-aware
icon.

Apple references:

- https://developer.apple.com/design/human-interface-guidelines/app-icons
- https://developer.apple.com/icon-composer/

Required tools:

- Xcode 27 (`actool` at `/Applications/Xcode.app/Contents/Developer/usr/bin/actool`)
- Icon Composer 27 (`ictool` at `/Applications/Icon Composer.app/Contents/Executables/ictool`)
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if `xcode-select` still points at Command Line Tools

## What actually ships

Source of truth:

```
launcher/resources/AppIcon.icon/
  icon.json
  Assets/Raven.svg
```

Compiled into the app:

```
Raven.app/Contents/Resources/Assets.car
Raven.app/Contents/Resources/AppIcon.icns
Raven.app/Contents/Info.plist
  CFBundleIconName = AppIcon
  CFBundleIconFile = AppIcon
```

Preview exports (not the app icon themselves):

```
launcher/build/icon-light.png
launcher/build/icon-dark.png
```

Those PNGs are Icon Composer flattened renders of Default and Dark. They
already include the system squircle. Never composite them back into the
`.icon` package.

## Reproduce this icon

From `launcher/`:

```bash
python3 scripts/generate-app-icon.py
./scripts/make-icon.sh          # also runs the generator, then ictool previews
swift build -c release
./scripts/make-app.sh           # actool -> Assets.car + AppIcon.icns
```

That is enough. Future sessions should not invent a new palette, scale, or
PNG pipeline unless the icon is being redesigned.

Constants locked in `generate-app-icon.py`:

- canvas 1024
- glyph occupies 64% of the canvas (`VIEWBOX 360.416` from `RavenLogo.svg`)
- transform `translate(184.320 176.320) scale(1.818343)` (8pt optical lift)
- plate light `display-p3:0.90588,0.88235,0.83137,1` (`#E7E1D4`)
- plate dark `display-p3:0.10196,0.16863,0.16471,1` (`#1A2B2A`)
- glyph is the inverse of the plate; tinted glyph is white

## Procedure

1. Keep the glyph as a **transparent SVG** in `AppIcon.icon/Assets/`.
   White fill is fine; Icon Composer recolors it via `fill-specializations`.
   Do **not** bake a background, roundrect, or inner border into the SVG/PNG.
   Regenerating that SVG is `generate-app-icon.py`, not a one-off snippet.

2. Describe appearances in `icon.json`:
   - document `fill-specializations` = plate color (light / dark / tinted)
   - layer `fill-specializations` = glyph color
   - `lighting: individual`, `specular: true`, translucency + shadow for
     Liquid Glass
   - `supported-platforms.squares = "shared"`

3. Preview with `ictool` (this is `scripts/make-icon.sh`):

```bash
ICTOOL="/Applications/Icon Composer.app/Contents/Executables/ictool"
ICON=launcher/resources/AppIcon.icon

"$ICTOOL" "$ICON" --export-image --output-file launcher/build/icon-light.png \
  --platform macOS --rendition Default --width 1024 --height 1024 --scale 1

"$ICTOOL" "$ICON" --export-image --output-file launcher/build/icon-dark.png \
  --platform macOS --rendition Dark --width 1024 --height 1024 --scale 1
```

`ictool --help` also documents `TintedDark` plus `--tint-color` / `--tint-strength`.

4. Compile with `actool`. Pass the **`.icon` package**, not `Assets.xcassets`.
   Compiling an `.appiconset` of 1024 PNGs on this toolchain produced an
   empty catalog. Compiling the `.icon` produces `Assets.car` + `AppIcon.icns`:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
actool launcher/resources/AppIcon.icon \
  --compile Raven.app/Contents/Resources \
  --platform macosx \
  --minimum-deployment-target 27.0 \
  --app-icon AppIcon \
  --output-partial-info-plist launcher/build/icon-partial.plist
```

Merge `CFBundleIconName` / `CFBundleIconFile` from the partial plist into
`Info.plist`. Both keys are required.

5. Ad-hoc sign the bundle (`codesign --force --sign - Raven.app`).
   Finder caches icons; `touch` the app and
   `lsregister -f Raven.app`, or relaunch Finder, if the old icon sticks.

End-to-end: `swift build -c release` then `launcher/scripts/make-app.sh`.

## `icon.json` (current)

Light plate `#E7E1D4` / dark plate `#1A2B2A`, glyph inverted.

```json
{
  "fill-specializations": [
    {"value": {"solid": "display-p3:0.90588,0.88235,0.83137,1.00000"}},
    {"appearance": "dark", "value": {"solid": "display-p3:0.10196,0.16863,0.16471,1.00000"}},
    {"appearance": "tinted", "value": {"solid": "extended-gray:0.35000,1.00000"}}
  ],
  "groups": [
    {
      "layers": [
        {
          "name": "Raven",
          "image-name": "Raven.svg",
          "fill-specializations": [
            {"value": {"solid": "display-p3:0.10196,0.16863,0.16471,1.00000"}},
            {"appearance": "dark", "value": {"solid": "display-p3:0.90588,0.88235,0.83137,1.00000"}},
            {"appearance": "tinted", "value": {"solid": "extended-gray:1.00000,1.00000"}}
          ]
        }
      ],
      "lighting": "individual",
      "shadow": {"kind": "neutral", "opacity": 0.3},
      "specular": true,
      "translucency": {"enabled": true, "value": 0.18}
    }
  ],
  "supported-platforms": {"squares": "shared"}
}
```

Color strings are `display-p3:r,g,b,a` or `extended-gray:white,alpha`.
`lighting` must be `individual` or `combined` (`none` is rejected).

## Building `Raven.svg` from `RavenLogo.svg`

Do not paste a one-off snippet. Run:

```bash
python3 launcher/scripts/generate-app-icon.py
```

That script is the locked transform: 1024 canvas, 64% glyph, 8pt lift,
white-filled path, no plate. It also rewrites `icon.json`. Changing those
numbers produces a different icon.

## What failed in this session (do not repeat)

- Drawing a roundrect into a 1024 PNG, then shipping `.icns`: Finder applies
  the squircle **again**, so you see a square-with-border inside the icon.
- Pointing `CFBundleIconName` at a `.icon` copied into Resources **without**
  compiling `Assets.car`: the app has no icon.
- Compiling `Assets.xcassets/AppIcon.appiconset` with light/dark 1024 PNGs:
  `actool` 27 accepted the catalog and wrote nothing. Compile the `.icon`.
- Using `image-name-specializations` to swap two already-rounded PNGs:
  those PNGs still contained a plate, so the inner square remained.
- Overwriting `build/icon-light.png` / `build/icon-dark.png` as if they were
  source assets. They are previews only. Source is the `.icon` package.
- `actool` needs full Xcode, not Command Line Tools, and a signed Xcode
  license (`sudo xcodebuild -license`).
- Copying a raw `.icon` into the bundle is optional for editing; Finder
  uses `Assets.car` + `AppIcon.icns`.

## `ictool` usage

```
ictool input-document --export-image \
  --output-file <path> --platform <platform> --rendition <rendition> \
  --width <w> --height <h> --scale <scale> \
  [--light-angle <angle>] [--tint-color <c>] [--tint-strength <s>]
```

Example platforms/renditions: `macOS` + `Default` or `Dark`;
`iOS` + `Default` / `TintedDark`.
