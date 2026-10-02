#!/usr/bin/env python3
"""Regenerates the built-in DMG window backgrounds (needs Pillow).
Each is rendered at 2x (1320x800) and 1x (660x400); build.sh merges them
into a Retina-aware TIFF. Icons sit at (165,200) and (495,200) in points."""
import math, os
from PIL import Image, ImageDraw, ImageFont

W, H = 660, 400
HERE = os.path.dirname(os.path.abspath(__file__))
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"

def base(s, top, bottom):
    img = Image.new("RGB", (W * s, H * s))
    d = ImageDraw.Draw(img)
    for y in range(H * s):
        t = y / (H * s - 1)
        d.line([(0, y), (W * s, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)))
    return img

def dots(s):
    img = base(s, (255, 250, 232), (250, 238, 200)); d = ImageDraw.Draw(img, "RGBA")
    for y in range(0, H, 22):
        for x in range(0, W, 22):
            ox = 11 if (y // 22) % 2 else 0
            r = 1.8 * s
            cx, cy = (x + ox) * s, y * s
            d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(214, 160, 0, 90))
    return img

def grid(s):
    img = base(s, (240, 244, 255), (222, 230, 252)); d = ImageDraw.Draw(img, "RGBA")
    for x in range(0, W + 1, 30):
        d.line([(x * s, 0), (x * s, H * s)], fill=(70, 100, 220, 40), width=s)
    for y in range(0, H + 1, 30):
        d.line([(0, y * s), (W * s, y * s)], fill=(70, 100, 220, 40), width=s)
    return img

def diagonal(s):
    img = base(s, (253, 240, 248), (245, 224, 238)); d = ImageDraw.Draw(img, "RGBA")
    for k in range(-H, W, 18):
        d.line([(k * s, H * s), ((k + H) * s, 0)], fill=(220, 60, 150, 30), width=3 * s)
    return img

def waves(s):
    img = base(s, (232, 250, 246), (210, 240, 234)); d = ImageDraw.Draw(img, "RGBA")
    for row in range(-20, H + 20, 16):
        pts = [(x * s, (row + 6 * math.sin(x / 34 + row / 40)) * s) for x in range(0, W + 1, 3)]
        d.line(pts, fill=(20, 150, 130, 45), width=s * 2)
    return img

def overlay(img, s):
    d = ImageDraw.Draw(img, "RGBA")
    # Arrow from app icon to Applications.
    y = 200 * s
    d.line([(250 * s, y), (400 * s, y)], fill=(30, 30, 40, 150), width=4 * s)
    d.polygon([(412 * s, y), (396 * s, y - 11 * s), (396 * s, y + 11 * s)], fill=(30, 30, 40, 150))
    f = ImageFont.truetype(FONT, 17 * s)
    msg = "Drag Captionate to Applications"
    w = d.textlength(msg, font=f)
    d.text(((W * s - w) / 2, 320 * s), msg, font=f, fill=(30, 30, 40, 200))
    return img

for name, fn in [("dots", dots), ("grid", grid), ("diagonal", diagonal), ("waves", waves)]:
    for s, suffix in [(1, ""), (2, "@2x")]:
        overlay(fn(s), s).save(os.path.join(HERE, f"background-{name}{suffix}.png"), optimize=True)
