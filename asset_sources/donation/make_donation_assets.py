"""Cut the "Fuel PIVXie" donation tiers out of the two design sheets
(Gemini_Generated_Image_bfk6mbfk6mbfk6mb.jpeg: the hooded, private style;
Gemini_Generated_Image_c7r4zrc7r4zrc7r4.jpeg: the translucent, public
style) and export them for assets/donation/.

Each tier is cropped from the sheet's grid ($20 from the phone mockup,
where it holds the siphon), captions and speech bubbles are blanked, and
the figure is cut out as in asset_sources/persona/make_persona_assets.py:
alpha = max(AI matte, colour-key matte against the crop's backdrop).

Usage (needs `pip install "rembg[cpu]" pillow numpy`; downloads the
BiRefNet model once):

    python make_donation_assets.py <sheet dir> <out dir>

<out dir>/assets/*.webp go to assets/donation/; <out dir>/preview_*.png
show them on the screen's stage colours.
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from rembg import new_session, remove

SRC = Path(sys.argv[1])
OUT = Path(sys.argv[2])
(OUT / "assets").mkdir(parents=True, exist_ok=True)

# Boxes in the sheets as displayed at 1932 x 1932 (private) and
# 2000 x 1493 (public), scaled to the originals; blanks are in the same
# coordinates.
SHEETS = {
    "private": ("Gemini_Generated_Image_bfk6mbfk6mbfk6mb.jpeg", 2048 / 1932, {
        "t1": ((1080, 300, 1360, 690), []),
        "t5": ((1505, 300, 1795, 690), []),
        "t10": ((1035, 815, 1375, 1210), []),
        "t20": ((215, 440, 850, 1000), []),
        "t50": ((1010, 1340, 1410, 1765), []),
        # "TO THE MOON!" bubble.
        "t100": ((1455, 1350, 1840, 1765), [(1716, 1350, 1840, 1458)]),
    }),
    "public": ("Gemini_Generated_Image_c7r4zrc7r4zrc7r4.jpeg", 1.2, {
        "t1": ((1020, 210, 1405, 525), []),
        "t5": ((1515, 210, 1905, 528), []),
        "t10": ((1012, 635, 1418, 952), []),
        "t20": ((200, 355, 765, 862), []),
        "t50": ((1022, 1030, 1412, 1385), []),
        # "TO THE MOON!" caption.
        "t100": ((1500, 1055, 1905, 1372), [(1696, 1334, 1905, 1372)]),
    }),
}
# Stage backdrops of the donation screen, for the previews.
STAGES = {"private": (26, 16, 51), "public": (20, 26, 61)}

session = new_session("birefnet-general")


def cut(img: Image.Image, blanks) -> Image.Image:
    rgb = np.asarray(img).astype(np.float32)
    border = np.concatenate(
        [rgb[:6].reshape(-1, 3), rgb[-6:].reshape(-1, 3),
         rgb[:, :6].reshape(-1, 3), rgb[:, -6:].reshape(-1, 3)]
    )
    bg = np.median(border, axis=0)

    ai = np.asarray(remove(img, session=session, only_mask=True)).astype(np.float32) / 255
    ai = np.clip((ai - 0.3) / 0.4, 0, 1)

    # The sheets' backdrops are grainy: a wider dead zone than for the
    # persona art keeps the grain out.
    dist = np.linalg.norm(rgb - bg, axis=2)
    t0, t1 = 24.0, 80.0
    ck = np.clip((dist - t0) / (t1 - t0), 0, 1)

    alpha = np.maximum(ai, ck)
    a = np.clip(alpha, 1e-3, 1)[..., None]
    fg = np.clip((rgb - (1 - a) * bg) / a, 0, 255)
    out_rgb = np.where((ck > ai)[..., None], fg, rgb)
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
    return sq


for style, (sheet, f, tiers) in SHEETS.items():
    src = Image.open(SRC / sheet).convert("RGB")
    previews = []
    for tier, (box, blanks) in tiers.items():
        x0, y0 = box[0], box[1]
        crop = src.crop(tuple(round(v * f) for v in box))
        local = [tuple(round((v - o) * f) for v, o in zip(b, (x0, y0, x0, y0)))
                 for b in blanks]
        sq = square(cut(crop, local))
        sq.save(OUT / "assets" / f"{style}_{tier}.webp", quality=90, method=6)
        print(style, tier, sq.size)
        pv = Image.new("RGBA", sq.size, STAGES[style] + (255,))
        pv.alpha_composite(sq)
        previews.append(pv.convert("RGB").resize((300, 300), Image.LANCZOS))
    sheet_pv = Image.new("RGB", (300 * len(previews), 300))
    for i, pv in enumerate(previews):
        sheet_pv.paste(pv, (300 * i, 0))
    sheet_pv.save(OUT / f"preview_{style}.png")
