#!/usr/bin/env python3
"""Compose the Kitsune app icon and menu bar template from Resources/icon-art.png.

The art is a free-standing fox mark on transparency. macOS app icons want the
rounded-square ground supplied by the app, so this lays the mark over one at the
Big Sur geometry: an 824x824 body centred in a 1024 canvas (the remaining margin
is what the Dock's shadow and reflection need -- drawing the body edge to edge
makes the icon sit visibly larger than every other app's).

The menu bar item is a different asset, not this one scaled: it is a template
image, so it must be black plus alpha only and macOS retints it for the light
and dark menu bar. It is derived from the mark's silhouette, which is the part
that still reads at 18pt.

Usage:
    python3 scripts/generate-icon.py

Writes Resources/AppIcon.iconset/*.png and Resources/MenuBarIconTemplate*.png.
`scripts/build-app.sh` runs iconutil over the iconset at build time.
"""
import os

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOURCES = os.path.join(ROOT, "Resources")
ART = os.path.join(RESOURCES, "icon-art.png")
ICONSET_DIR = os.path.join(RESOURCES, "AppIcon.iconset")

CANVAS = 1024
BODY = 824               # the rounded square itself, centred in CANVAS
CORNER_RADIUS = 185      # 0.225 * BODY -- the macOS 11+ squircle
ART_WIDTH = 0.70         # mark width as a fraction of BODY

BG_TOP = (42, 39, 63)      # rose-pine surface
BG_BOTTOM = (25, 23, 36)   # rose-pine base


def ground():
    """The rounded-square body, vertical gradient, centred with margin."""
    grad = Image.new("RGBA", (1, BODY))
    for y in range(BODY):
        t = y / (BODY - 1)
        grad.putpixel((0, y), tuple(
            int(a + (b - a) * t) for a, b in zip(BG_TOP, BG_BOTTOM)
        ) + (255,))
    grad = grad.resize((BODY, BODY))

    mask = Image.new("L", (BODY * 4, BODY * 4), 0)
    from PIL import ImageDraw
    ImageDraw.Draw(mask).rounded_rectangle(
        [(0, 0), (BODY * 4 - 1, BODY * 4 - 1)], radius=CORNER_RADIUS * 4, fill=255
    )
    grad.putalpha(mask.resize((BODY, BODY), Image.LANCZOS))

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    canvas.alpha_composite(grad, ((CANVAS - BODY) // 2, (CANVAS - BODY) // 2))
    return canvas


def master():
    """Ground plus the mark, trimmed to its own alpha and scaled to fit."""
    art = Image.open(ART).convert("RGBA")
    art = art.crop(art.getchannel("A").point(lambda a: 255 if a > 8 else 0).getbbox())

    width = int(BODY * ART_WIDTH)
    height = round(width * art.height / art.width)
    art = art.resize((width, height), Image.LANCZOS)

    canvas = ground()
    canvas.alpha_composite(art, ((CANVAS - width) // 2, (CANVAS - height) // 2))
    return canvas


def menu_bar_template():
    """Black silhouette of the mark, padded inside a square, for isTemplate use."""
    art = Image.open(ART).convert("RGBA")
    art = art.crop(art.getchannel("A").point(lambda a: 255 if a > 8 else 0).getbbox())

    black = Image.new("RGBA", art.size, (0, 0, 0, 0))
    black.putalpha(art.getchannel("A"))

    side = max(art.size)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.alpha_composite(black, ((side - art.width) // 2, (side - art.height) // 2))
    return square


SPECS = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]


def main():
    os.makedirs(ICONSET_DIR, exist_ok=True)
    source = master()
    cache = {}
    for name, size in SPECS:
        if size not in cache:
            cache[size] = source.resize((size, size), Image.LANCZOS)
        cache[size].save(os.path.join(ICONSET_DIR, name))
        print(f"wrote {name} ({size}x{size})")

    template = menu_bar_template()
    for name, size in [("MenuBarIconTemplate.png", 18), ("MenuBarIconTemplate@2x.png", 36)]:
        template.resize((size, size), Image.LANCZOS).save(os.path.join(RESOURCES, name))
        print(f"wrote {name} ({size}x{size})")


if __name__ == "__main__":
    main()
