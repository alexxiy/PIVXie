"""PIVXie launcher icon sources from the artwork (app_icon_orig.jpg).

Writes 1024 px sources for flutter_launcher_icons, which scales them to
every Android density (mdpi..xxxhdpi), every iOS size and the desktop
icons:

- icon.png              iOS / Windows: the tile, opaque, square.
- macos-icon.png        macOS / Android legacy: the tile with
                        transparent corners and a small margin.
- adaptive_foreground.png  Android 8+ foreground: the pixie and shield cut
                        out (BiRefNet), transparent.
- adaptive_background.png  Android 8+ background: the tile's dark violet.
- adaptive_monochrome.png  Android 13 themed (monochrome) icon.

Usage: python make_icon.py <app_icon_orig.jpg> <out dir>
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter
from rembg import new_session, remove

SRC = Path(sys.argv[1])
OUT = Path(sys.argv[2])
OUT.mkdir(parents=True, exist_ok=True)
S = 1024

art = Image.open(SRC).convert("RGB")
W, H = art.size
k = W / 2048  # geometry below measured on the 2048 px artwork

# The tile (dark rim around the neon frame).
TILE = tuple(round(v * k) for v in (146, 112, 1901, 1903))
RADIUS = round(262 * k)


def tile_mask(size, box, radius, scale=4):
    """Anti-aliased rounded rectangle."""
    big = Image.new("L", (size[0] * scale, size[1] * scale), 0)
    ImageDraw.Draw(big).rounded_rectangle(
        [v * scale for v in box], radius=radius * scale, fill=255
    )
    return big.resize(size, Image.LANCZOS)


x0, y0, x1, y1 = TILE
side = max(x1 - x0, y1 - y0)
cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
sq = (round(cx - side / 2), round(cy - side / 2),
      round(cx + side / 2), round(cy + side / 2))

# --- tile with alpha
mask = tile_mask((W, H), TILE, RADIUS)
tile_rgba = art.copy()
tile_rgba.putalpha(mask)
tile_rgba = tile_rgba.crop(sq)

# icon.png: opaque; outside the tile (masked away by iOS / Windows
# shapes anyway) takes the rim colour instead of the grid backdrop.
rim = Image.new("RGB", tile_rgba.size, (20, 14, 46))
rim.paste(tile_rgba, (0, 0), tile_rgba)
rim.resize((S, S), Image.LANCZOS).save(OUT / "icon.png", optimize=True)

# macos-icon.png: tile on transparent with ~6% margin.
inner = round(S * 0.88)
t = tile_rgba.convert("RGBa").resize((inner, inner), Image.LANCZOS).convert("RGBA")
mac = Image.new("RGBA", (S, S), (0, 0, 0, 0))
mac.alpha_composite(t, ((S - inner) // 2, (S - inner) // 2))
mac.save(OUT / "macos-icon.png", optimize=True)

# --- adaptive foreground: cut the character out of the tile interior.
INNER = tuple(round(v * k) for v in (285, 255, 1765, 1760))
interior = art.crop(INNER)
matte = remove(interior, session=new_session("birefnet-general"), only_mask=True)
m = np.asarray(matte).astype(np.float32) / 255
m = np.clip((m - 0.3) / 0.4, 0, 1)
fg = interior.copy()
fg.putalpha(Image.fromarray((m * 255).astype(np.uint8)))
bbox = fg.getbbox()
fg = fg.crop(bbox)
# flutter_launcher_icons insets the foreground by 16% per side (the
# 66/108 dp safe zone); 80% of that keeps wings and shield inside a
# circular mask.
fw, fh = fg.size
scale = (S * 0.80) / max(fw, fh)
fg = fg.convert("RGBa").resize((round(fw * scale), round(fh * scale)),
                               Image.LANCZOS).convert("RGBA")
canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
canvas.alpha_composite(fg, ((S - fg.width) // 2, (S - fg.height) // 2))
canvas.save(OUT / "adaptive_foreground.png", optimize=True)

# --- adaptive background: radial violet like the tile interior.
yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)
r = np.sqrt((xx - S / 2) ** 2 + (yy - S / 2) ** 2) / (S / 2 * 1.2)
r = np.clip(r, 0, 1)[..., None]
centre = np.array([52, 30, 112], np.float32)
edge = np.array([18, 12, 44], np.float32)
bg = (centre * (1 - r) + edge * r).astype(np.uint8)
Image.fromarray(bg, "RGB").save(OUT / "adaptive_background.png", optimize=True)

# --- monochrome: white silhouette of the foreground.
alpha = canvas.getchannel("A")
mono = Image.merge("LA", (Image.new("L", (S, S), 255), alpha))
mono.save(OUT / "adaptive_monochrome.png", optimize=True)

# --- previews: Android circle / squircle masks, iOS, legacy.
def preview_adaptive(shape):
    full = Image.open(OUT / "adaptive_background.png").convert("RGBA")
    f = canvas.resize((round(S * 0.68),) * 2, Image.LANCZOS)
    full.alpha_composite(f, ((S - f.width) // 2, (S - f.height) // 2))
    # launchers show the central 72/108 of the layers
    vis = round(S * 72 / 108)
    off = (S - vis) // 2
    full = full.crop((off, off, off + vis, off + vis)).resize((256, 256), Image.LANCZOS)
    m = Image.new("L", (256 * 4, 256 * 4), 0)
    d = ImageDraw.Draw(m)
    if shape == "circle":
        d.ellipse([0, 0, 1023, 1023], fill=255)
    else:
        d.rounded_rectangle([0, 0, 1023, 1023], radius=300, fill=255)
    full.putalpha(m.resize((256, 256), Image.LANCZOS))
    return full

sheet = Image.new("RGBA", (256 * 4 + 50, 300), (236, 236, 240, 255))
sheet.alpha_composite(preview_adaptive("circle"), (10, 20))
sheet.alpha_composite(preview_adaptive("squircle"), (276, 20))
ios = Image.open(OUT / "icon.png").convert("RGBA").resize((256, 256), Image.LANCZOS)
m = Image.new("L", (1024, 1024), 0)
ImageDraw.Draw(m).rounded_rectangle([0, 0, 1023, 1023], radius=229, fill=255)
ios.putalpha(m.resize((256, 256), Image.LANCZOS))
sheet.alpha_composite(ios, (542, 20))
sheet.alpha_composite(mac.resize((256, 256), Image.LANCZOS), (808, 20))
sheet.convert("RGB").save(OUT / "preview.png")
