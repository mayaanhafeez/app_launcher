#!/usr/bin/env python3
"""Generate the OrbitLauncher placeholder app icon as a macOS .iconset.

Draws a minimal rounded-square ground with a simple orbit-ring + planet
glyph -- no external assets, no dependencies beyond Pillow. Renders at 2x
supersampling and downsamples with LANCZOS for clean edges at every size.

This is a PLACEHOLDER intended for design review, not final artwork.

Usage:
    python3 scripts/generate-icon.py

Regenerates Resources/AppIcon.iconset/*.png. Run `iconutil -c icns` on that
directory (scripts/build-app.sh already does this at build time) to produce
the .icns consumed by the app bundle.
"""
import math
import os

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICONSET_DIR = os.path.join(ROOT, "Resources", "AppIcon.iconset")

# macOS Big Sur+ style: app supplies the full rounded-square ground itself.
CORNER_RATIO = 0.1808

BG_TOP = (30, 27, 60)       # deep indigo
BG_BOTTOM = (58, 33, 96)    # muted purple
RING_COLOR = (124, 156, 255, 235)   # soft periwinkle
PLANET_COLOR = (255, 200, 87, 255)  # warm amber accent
CORE_COLOR = (238, 240, 255, 255)   # near-white core


def rounded_square(size):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    radius = int(size * CORNER_RATIO)

    # Vertical gradient background, then mask to a rounded rect.
    grad = Image.new("RGBA", (1, size), (0, 0, 0, 0))
    for y in range(size):
        t = y / max(1, size - 1)
        r = int(BG_TOP[0] + (BG_BOTTOM[0] - BG_TOP[0]) * t)
        g = int(BG_TOP[1] + (BG_BOTTOM[1] - BG_TOP[1]) * t)
        b = int(BG_TOP[2] + (BG_BOTTOM[2] - BG_TOP[2]) * t)
        grad.putpixel((0, y), (r, g, b, 255))
    grad = grad.resize((size, size))

    mask = Image.new("L", (size, size), 0)
    mask_draw = ImageDraw.Draw(mask)
    mask_draw.rounded_rectangle([(0, 0), (size - 1, size - 1)], radius=radius, fill=255)

    img.paste(grad, (0, 0), mask)
    return img


def draw_orbit(img, size):
    draw = ImageDraw.Draw(img)
    cx, cy = size / 2, size / 2

    # Tilted elliptical ring, drawn as a stroked ellipse then rotated.
    ring_w = size * 0.62
    ring_h = size * 0.30
    stroke = max(2, int(size * 0.028))

    ring_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ring_draw = ImageDraw.Draw(ring_layer)
    bbox = [cx - ring_w / 2, cy - ring_h / 2, cx + ring_w / 2, cy + ring_h / 2]
    ring_draw.ellipse(bbox, outline=RING_COLOR, width=stroke)
    ring_layer = ring_layer.rotate(-24, resample=Image.BICUBIC, center=(cx, cy))
    img.alpha_composite(ring_layer)

    # Central "sun" core.
    core_r = size * 0.115
    draw.ellipse([cx - core_r, cy - core_r, cx + core_r, cy + core_r], fill=CORE_COLOR)

    # Soft glow behind the core.
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    glow_r = core_r * 1.9
    glow_draw.ellipse([cx - glow_r, cy - glow_r, cx + glow_r, cy + glow_r], fill=(238, 240, 255, 70))
    glow = glow.filter(ImageFilter.GaussianBlur(size * 0.02))
    img.alpha_composite(glow, (0, 0))
    draw = ImageDraw.Draw(img)
    draw.ellipse([cx - core_r, cy - core_r, cx + core_r, cy + core_r], fill=CORE_COLOR)

    # Orbiting "planet" dot, positioned on the tilted ring at roughly
    # the 2 o'clock position of the ellipse before rotation.
    angle = math.radians(-40)
    px = cx + (ring_w / 2) * math.cos(angle)
    py = cy + (ring_h / 2) * math.sin(angle)
    # Rotate that point by the same -24 degree tilt around the center.
    theta = math.radians(-24)
    rx = cx + (px - cx) * math.cos(theta) - (py - cy) * math.sin(theta)
    ry = cy + (px - cx) * math.sin(theta) + (py - cy) * math.cos(theta)
    planet_r = size * 0.075
    draw.ellipse([rx - planet_r, ry - planet_r, rx + planet_r, ry + planet_r], fill=PLANET_COLOR)

    return img


def render(size):
    supersample = 4
    big = size * supersample
    img = rounded_square(big)
    img = draw_orbit(img, big)
    return img.resize((size, size), Image.LANCZOS)


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
    cache = {}
    for name, size in SPECS:
        if size not in cache:
            cache[size] = render(size)
        cache[size].save(os.path.join(ICONSET_DIR, name))
        print(f"wrote {name} ({size}x{size})")


if __name__ == "__main__":
    main()
