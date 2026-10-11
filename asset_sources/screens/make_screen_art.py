"""Cut the PIVXie screen artwork (welcome, add wallet) out of its dark
background and export density variants for Flutter.

Same matting as ../persona/make_persona_assets.py: alpha = max(AI matte,
colour key against the backdrop), colour-keyed pixels decontaminated.
Each image is cropped to its content (keeping its aspect ratio) and
scaled to fit a BASE x BASE logical box at 1x.

Usage (needs `pip install "rembg[cpu]" pillow numpy`):

    python make_screen_art.py <src dir> <out dir>

<src dir> holds PIVXie_app_welcome_screen.jpg and
PIVXie_add_wallet_sceen.jpeg; <out dir>/assets/ goes to assets/persona/
and <out dir>/full/ to asset_sources/screens/.
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from rembg import new_session, remove

SRC = Path(sys.argv[1])
OUT = Path(sys.argv[2])
OUT.mkdir(parents=True, exist_ok=True)
BASE = 280
DENSITIES = {"": 1.0, "1.5x": 1.5, "2.0x": 2.0, "3.0x": 3.0, "4.0x": 4.0}

session = new_session("birefnet-general")

# name, source, drop everything below this fraction of the height (the
# floor shadow under the welcome artwork)
JOBS = [
    ("pivxie_welcome", "PIVXie_app_welcome_screen.jpg", 0.835),
    ("pivxie_add_wallet", "PIVXie_add_wallet_sceen.jpeg", None),
]


def cut(path: Path, floor):
    img = Image.open(path).convert("RGB")
    rgb = np.asarray(img).astype(np.float32)
    h, w, _ = rgb.shape

    border = np.concatenate(
        [rgb[:8].reshape(-1, 3), rgb[-8:].reshape(-1, 3),
         rgb[:, :8].reshape(-1, 3), rgb[:, -8:].reshape(-1, 3)]
    )
    bg = np.median(border, axis=0)

    ai = np.asarray(remove(img, session=session, only_mask=True)).astype(np.float32) / 255
    dist = np.linalg.norm(rgb - bg, axis=2)
    t0, t1 = 14.0, 70.0
    ck = np.clip((dist - t0) / (t1 - t0), 0, 1)
    ai = np.clip((ai - 0.3) / 0.4, 0, 1)

    alpha = np.maximum(ai, ck)
    a = np.clip(alpha, 1e-3, 1)[..., None]
    fg = np.clip((rgb - (1 - a) * bg) / a, 0, 255)
    out_rgb = np.where((ck > ai)[..., None], fg, rgb)
    alpha[alpha < 0.02] = 0
    if floor is not None:
        alpha[int(h * floor):] = 0

    # Crop to what is visible: rows/columns with a few clearly opaque
    # pixels (stray faint JPEG noise near the edges doesn't count), and
    # clear everything outside.
    solid = alpha > 0.25
    cols = np.nonzero(solid.sum(axis=0) >= 3)[0]
    rows = np.nonzero(solid.sum(axis=1) >= 3)[0]
    box = (cols.min(), rows.min(), cols.max() + 1, rows.max() + 1)
    print(path.name, "faint pixels outside the crop:",
          int((alpha > 0.03).sum() - (alpha[box[1]:box[3], box[0]:box[2]] > 0.03).sum()))
    keep = np.zeros_like(alpha)
    x0, y0, x1, y1 = box
    m = int(max(x1 - x0, y1 - y0) * 0.01)
    keep[max(y0 - m, 0):y1 + m, max(x0 - m, 0):x1 + m] = 1
    alpha *= keep
    rgba = np.dstack([out_rgb, alpha * 255]).round().astype(np.uint8)
    im = Image.fromarray(rgba, "RGBA")
    return im, box, bg


for name, src, floor in JOBS:
    im, box, bg = cut(SRC / src, floor)
    x0, y0, x1, y1 = box
    pad = int(max(x1 - x0, y1 - y0) * 0.01)
    content = im.crop((max(x0 - pad, 0), max(y0 - pad, 0),
                       min(x1 + pad, im.width), min(y1 + pad, im.height)))
    print(name, "backdrop", bg.round(), "content", content.size)
    full = OUT / "full"
    full.mkdir(parents=True, exist_ok=True)
    content.save(full / f"{name}.png", optimize=True)
    cw, ch = content.size
    for folder, scale in DENSITIES.items():
        f = BASE * scale / max(cw, ch)
        size = (round(cw * f), round(ch * f))
        d = OUT / "assets" / folder
        d.mkdir(parents=True, exist_ok=True)
        content.convert("RGBa").resize(size, Image.LANCZOS).convert("RGBA").save(
            d / f"{name}.png", optimize=True)
    for tag, col in [("dark", (42, 45, 52)), ("oled", (0, 0, 0)), ("light", (245, 245, 247))]:
        pv = Image.new("RGBA", content.size, col + (255,))
        pv.alpha_composite(content)
        pv.convert("RGB").resize((cw * 600 // ch, 600), Image.LANCZOS).save(
            OUT / f"preview_{name}_{tag}.png")
