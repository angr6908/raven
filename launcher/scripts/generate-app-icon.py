#!/usr/bin/env python3
"""Rebuild AppIcon.icon from RavenLogo.svg with the locked macOS 27 treatment.

This is the exact recipe used for the current launcher icon. Do not change
the canvas, scale, optical lift, or colors unless the icon is being redesigned.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GLYPH = ROOT / "resources" / "RavenLogo.svg"
ICON = ROOT / "resources" / "AppIcon.icon"
ASSETS = ICON / "Assets"

CANVAS = 1024
VIEWBOX = 360.416
GLYPH_FRACTION = 0.64
OPTICAL_LIFT = 8.0

# Cream plate / deep pine glyph (inverted in Dark).
PLATE_LIGHT = "display-p3:0.90588,0.88235,0.83137,1.00000"
PLATE_DARK = "display-p3:0.10196,0.16863,0.16471,1.00000"
PLATE_TINTED = "extended-gray:0.35000,1.00000"
GLYPH_LIGHT = PLATE_DARK
GLYPH_DARK = PLATE_LIGHT
GLYPH_TINTED = "extended-gray:1.00000,1.00000"


def glyph_path(svg_text: str) -> str:
    match = re.search(r'<path d="([^"]+)"', svg_text)
    if not match:
        raise SystemExit(f"no <path d> in {GLYPH}")
    return match.group(1)


def write_raven_svg(path_d: str) -> None:
    scale = (CANVAS * GLYPH_FRACTION) / VIEWBOX
    tx = (CANVAS - VIEWBOX * scale) / 2
    ty = tx - OPTICAL_LIFT
    ASSETS.mkdir(parents=True, exist_ok=True)
    (ASSETS / "Raven.svg").write_text(
        '<svg xmlns="http://www.w3.org/2000/svg" '
        f'width="{CANVAS}" height="{CANVAS}" viewBox="0 0 {CANVAS} {CANVAS}">\n'
        f'  <g transform="translate({tx:.3f} {ty:.3f}) scale({scale:.6f})">\n'
        f'    <path fill="white" d="{path_d}"/>\n'
        "  </g>\n"
        "</svg>\n"
    )
    for leftover in ("AppIcon-light.png", "AppIcon-dark.png"):
        extra = ASSETS / leftover
        if extra.exists():
            extra.unlink()


def write_icon_json() -> None:
    icon = {
        "fill-specializations": [
            {"value": {"solid": PLATE_LIGHT}},
            {"appearance": "dark", "value": {"solid": PLATE_DARK}},
            {"appearance": "tinted", "value": {"solid": PLATE_TINTED}},
        ],
        "groups": [
            {
                "layers": [
                    {
                        "name": "Raven",
                        "image-name": "Raven.svg",
                        "fill-specializations": [
                            {"value": {"solid": GLYPH_LIGHT}},
                            {"appearance": "dark", "value": {"solid": GLYPH_DARK}},
                            {"appearance": "tinted", "value": {"solid": GLYPH_TINTED}},
                        ],
                    }
                ],
                "lighting": "individual",
                "shadow": {"kind": "neutral", "opacity": 0.3},
                "specular": True,
                "translucency": {"enabled": True, "value": 0.18},
            }
        ],
        "supported-platforms": {"squares": "shared"},
    }
    ICON.mkdir(parents=True, exist_ok=True)
    (ICON / "icon.json").write_text(json.dumps(icon, indent=2) + "\n")


def main() -> None:
    write_raven_svg(glyph_path(GLYPH.read_text()))
    write_icon_json()
    print(f"wrote {ICON}")


if __name__ == "__main__":
    main()
