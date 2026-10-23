"""Cut the "Fuel PIVXie" donation art out of its backdrops and export it
for assets/donation/.

The sources are one 2048 x 2048 picture per tier and style
(graphics/PIVXie/Donation): private_* is the hooded PIVXie (paid from the
shielded balance), public_* the translucent one; *_thank_you is the
screen after a donation. English captions are blanked (the screen is
translated), and the figure is cut out as in
asset_sources/persona/make_persona_assets.py:
alpha = max(AI matte, colour-key matte against the picture's backdrop).
Where a dark face is the backdrop's colour, both mattes miss it: big
enclosed holes are filled in.

Usage (needs `pip install "rembg[cpu]" pillow numpy scipy`; downloads the
BiRefNet model once):

    python make_donation_assets.py <source dir> <out dir>

<out dir>/assets/*.webp go to assets/donation/; <out dir>/preview_*.png
show them on the screen's stage colours.
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from rembg import new_session, remove
from scipy import ndimage

SRC = Path(sys.argv[1])
OUT = Path(sys.argv[2])
(OUT / "assets").mkdir(parents=True, exist_ok=True)

# The stage shows PIVXie at up to 215 logical px: 1024 px stays sharp up
# to 4.7x.
SIDE = 1024

# Asset name: (source name without the style prefix, blanks in source
# pixels, whether to fill the face).
TIERS = {
    "private": {
        "t1": ("01_tiny_drop", [], False),
        "t5": ("05_cyber_mug", [], False),
        "t10": ("10_double_shot", [], False),
        "t20": ("20_zk_nitro_siphon", [], False),
        "t50": ("50_direct_iv", [], False),
        # "TO THE MOON!" bubble.
        "t100": ("100_moon_boost", [(1280, 380, 1720, 745)], False),
        "thanks": ("thank_you", [], True),
    },
    "public": {
        "t1": ("01_tiny_drop", [], False),
        "t5": ("05_cyber_mug", [], False),
        "t10": ("10_double_shot", [], False),
        "t20": ("20_zk_nitro_siphon", [], False),
        "t50": ("50_direct_iv", [], False),
        # "TO THE MOON!" caption.
        "t100": ("100_moon_boost", [(1030, 1530, 1740, 1660)], False),
        "thanks": ("thank_you", [], True),
    },
}
# Stage backdrops of the donation screen, for the previews.
STAGES = {"private": (26, 16, 51), "public": (20, 26, 61)}

session = new_session("birefnet-general")


def cut(img: Image.Image, blanks, fill: bool) -> Image.Image:
    rgb = np.asarray(img).astype(np.float32)
    border = np.concatenate(
        [rgb[:6].reshape(-1, 3), rgb[-6:].reshape(-1, 3),
         rgb[:, :6].reshape(-1, 3), rgb[:, -6:].reshape(-1, 3)]
    )
    bg = np.median(border, axis=0)

    ai = np.asarray(remove(img, session=session, only_mask=True)).astype(np.float32) / 255
    ai = np.clip((ai - 0.3) / 0.4, 0, 1)

    # The backdrops are grainy: a wider dead zone than for the persona
    # art keeps the grain out.
    dist = np.linalg.norm(rgb - bg, axis=2)
    t0, t1 = 24.0, 80.0
    ck = np.clip((dist - t0) / (t1 - t0), 0, 1)

    alpha = np.maximum(ai, ck)
    a = np.clip(alpha, 1e-3, 1)[..., None]
    fg = np.clip((rgb - (1 - a) * bg) / a, 0, 255)
    out_rgb = np.where((ck > ai)[..., None], fg, rgb)
    if fill:
        # Holes bigger than 0.5% of the picture (the face, not the gaps
        # between arms and props), grown over their soft edges.
        solid = alpha > 0.5
        holes = ndimage.binary_fill_holes(solid) & ~solid
        labels, n = ndimage.label(holes)
        sizes = ndimage.sum(holes, labels, range(1, n + 1))
        big = np.isin(labels, 1 + np.flatnonzero(sizes > 0.005 * holes.size))
        big = ndimage.binary_dilation(big, iterations=4)
        alpha[big] = 1
        out_rgb[big] = rgb[big]
    for x0, y0, x1, y1 in blanks:
        alpha[y0:y1, x0:x1] = 0
    alpha[alpha < 0.04] = 0

    rgba = np.dstack([out_rgb, alpha * 255]).round().astype(np.uint8)
    im = Image.fromarray(rgba, "RGBA")
    ys, xs = np.nonzero(alpha > 0.05)
    return im.crop((xs.min(), ys.min(), xs.max() + 1, ys.max() + 1))


def square(content: Image.Image) -> Image.Image:
    w, h = content.size
    side = int(max(w, h) * 1.02)
    sq = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    # Figures stand on the bottom edge of the box.
    sq.paste(content, ((side - w) // 2, side - h - (side - max(w, h)) // 2))
    if side > SIDE:
        sq = sq.resize((SIDE, SIDE), Image.LANCZOS)
    return sq


for style, tiers in TIERS.items():
    previews = []
    for name, (source, blanks, fill) in tiers.items():
        src = Image.open(SRC / f"{style}_{source}.png").convert("RGB")
        sq = square(cut(src, blanks, fill))
        sq.save(OUT / "assets" / f"{style}_{name}.webp", quality=90, method=6)
        print(style, name, sq.size)
        pv = Image.new("RGBA", sq.size, STAGES[style] + (255,))
        pv.alpha_composite(sq)
        previews.append(pv.convert("RGB").resize((300, 300), Image.LANCZOS))
    sheet_pv = Image.new("RGB", (300 * len(previews), 300))
    for i, pv in enumerate(previews):
        sheet_pv.paste(pv, (300 * i, 0))
    sheet_pv.save(OUT / f"preview_{style}.png")
