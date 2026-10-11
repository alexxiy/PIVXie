"""PIVXie launcher icon sources from the artwork (app_icon_orig_v2.jpg:
the winged Void Pixie with the PIVX shield on a violet gradient tile).

Writes 1024 px sources for flutter_launcher_icons, which scales them to
every Android density (mdpi..xxxhdpi), every iOS size and the desktop
icons:

- icon.png                 iOS / Windows: full-bleed square (the
                           platforms apply their own corner mask).
- macos-icon.png           macOS / Android legacy: rounded tile on
                           transparent with a small margin.
- adaptive_foreground.png  Android 8+ foreground: the emblem cut out.
- adaptive_background.png  Android 8+ background: the violet gradient.
- adaptive_monochrome.png  Android 13 themed icon: the emblem's
                           silhouette with the "P" and eyes cut out.

The artwork's tile has white corners, so the background is rebuilt as a
smooth gradient fitted to the artwork's own background pixels and the
emblem (BiRefNet matte) is put back on it.

Usage: python make_icon.py <app_icon_orig_v2.jpg> <out dir>
(needs `pip install "rembg[cpu]" pillow numpy`)
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from rembg import new_session, remove

SRC = Path(sys.argv[1])
OUT = Path(sys.argv[2])
OUT.mkdir(parents=True, exist_ok=True)
S = 1024

art = Image.open(SRC).convert("RGB").resize((S, S), Image.LANCZOS)
rgb = np.asarray(art).astype(np.float32)

# --- emblem matte
matte = remove(art, session=new_session("birefnet-general"), only_mask=True)
m = np.asarray(matte).astype(np.float32) / 255
m = np.clip((m - 0.3) / 0.4, 0, 1)
# keep the white tile corners out of the matte
white = rgb.min(axis=2) > 200
m[white & (m < 0.99)] = 0

# --- background: 2D quadratic fit per channel over background pixels
yy, xx = np.mgrid[0:S, 0:S].astype(np.float32) / S - 0.5
feats = np.stack([np.ones_like(xx), xx, yy, xx * xx, yy * yy, xx * yy], -1)
bgmask = (m < 0.02) & ~white
# stay clear of the tile's rounded edge (antialiased with white)
edge = np.sqrt(xx**2 + yy**2) < 0.47
sel = bgmask & edge
A = feats[sel]
bg = np.zeros_like(rgb)
for c in range(3):
    coef, *_ = np.linalg.lstsq(A, rgb[..., c][sel], rcond=None)
    bg[..., c] = feats @ coef
bg = np.clip(bg, 0, 255)
Image.fromarray(bg.astype(np.uint8)).save(OUT / "adaptive_background.png", optimize=True)

# emblem RGBA (original colours, matte alpha)
emblem = Image.fromarray(
    np.dstack([rgb, m * 255]).round().astype(np.uint8), "RGBA"
)

# --- icon.png: emblem back on the fitted background, full bleed
full = Image.fromarray(bg.astype(np.uint8)).convert("RGBA")
full.alpha_composite(emblem)
full.convert("RGB").save(OUT / "icon.png", optimize=True)

# --- macos-icon.png: rounded tile, ~6% margin
def rounded(img, radius_frac, scale=4):
    big = Image.new("L", (S * scale, S * scale), 0)
    ImageDraw.Draw(big).rounded_rectangle(
        [0, 0, S * scale - 1, S * scale - 1], radius=round(S * scale * radius_frac), fill=255
    )
    out = img.copy()
    out.putalpha(big.resize((S, S), Image.LANCZOS))
    return out

inner = round(S * 0.88)
tile = rounded(full, 0.2237).convert("RGBa").resize((inner, inner), Image.LANCZOS).convert("RGBA")
mac = Image.new("RGBA", (S, S), (0, 0, 0, 0))
mac.alpha_composite(tile, ((S - inner) // 2, (S - inner) // 2))
mac.save(OUT / "macos-icon.png", optimize=True)

# --- adaptive foreground: emblem centred, 80% of the 16%-inset area
bbox = emblem.getbbox()
cut = emblem.crop(bbox)
scale = (S * 0.80) / max(cut.size)
cut = cut.convert("RGBa").resize(
    (round(cut.width * scale), round(cut.height * scale)), Image.LANCZOS
).convert("RGBA")
fg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
fg.alpha_composite(cut, ((S - cut.width) // 2, (S - cut.height) // 2))
fg.save(OUT / "adaptive_foreground.png", optimize=True)

# --- monochrome: silhouette, light details (P, eyes) cut out
f = np.asarray(fg).astype(np.float32)
lum = f[..., :3].mean(axis=2)
alpha = f[..., 3] / 255
hole = np.clip((lum - 110) / 60, 0, 1)  # the white/cyan P, violet eyes
mono_a = alpha * (1 - hole)
# shield fill is mid-violet: keep it solid unless clearly light
mono = Image.merge(
    "LA",
    (Image.new("L", (S, S), 255), Image.fromarray((mono_a * 255).astype(np.uint8))),
)
mono.save(OUT / "adaptive_monochrome.png", optimize=True)

# --- preview sheet: Android circle / squircle, iOS, legacy, themed
def adaptive_preview(shape, layer_fg, layer_bg):
    canvas = layer_bg.convert("RGBA").copy()
    f2 = layer_fg.resize((round(S * 0.68),) * 2, Image.LANCZOS)
    canvas.alpha_composite(f2, ((S - f2.width) // 2, (S - f2.height) // 2))
    vis = round(S * 72 / 108)
    off = (S - vis) // 2
    canvas = canvas.crop((off, off, off + vis, off + vis)).resize((256, 256), Image.LANCZOS)
    mk = Image.new("L", (1024, 1024), 0)
    d = ImageDraw.Draw(mk)
    if shape == "circle":
        d.ellipse([0, 0, 1023, 1023], fill=255)
    else:
        d.rounded_rectangle([0, 0, 1023, 1023], radius=300, fill=255)
    canvas.putalpha(mk.resize((256, 256), Image.LANCZOS))
    return canvas

themed_bg = Image.new("RGB", (S, S), (40, 40, 52))
themed_fg = Image.merge(
    "RGBA",
    (
        Image.new("L", (S, S), 200),
        Image.new("L", (S, S), 190),
        Image.new("L", (S, S), 255),
        mono.getchannel("A"),
    ),
)
sheet = Image.new("RGBA", (256 * 5 + 60, 300), (236, 236, 240, 255))
sheet.alpha_composite(adaptive_preview("circle", fg, Image.open(OUT / "adaptive_background.png")), (10, 20))
sheet.alpha_composite(adaptive_preview("squircle", fg, Image.open(OUT / "adaptive_background.png")), (276, 20))
ios = rounded(full, 0.2237).resize((256, 256), Image.LANCZOS)
sheet.alpha_composite(ios, (542, 20))
sheet.alpha_composite(mac.resize((256, 256), Image.LANCZOS), (808, 20))
sheet.alpha_composite(adaptive_preview("circle", themed_fg, themed_bg), (1074, 20))
sheet.convert("RGB").save(OUT / "preview.png")
