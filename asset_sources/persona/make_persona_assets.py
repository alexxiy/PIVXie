"""Cut the PIVXie mascots out of their dark background and export
density variants for Flutter (1x = 140 logical px).

alpha = max(AI matte, colour-key matte against the backdrop colour):
the AI matte keeps the dark cloak solid, the colour key keeps sparkles,
pixels and glows. Colour-keyed pixels are decontaminated (backdrop
colour removed) so glows don't leave a navy fringe.

Usage (needs `pip install "rembg[cpu]" pillow numpy`; downloads the
BiRefNet model once):

    python make_persona_assets.py birefnet-general <src dir> <out dir>

<src dir> holds PIVXie_public.jpeg / PIVXie_private.jpeg (the artwork);
<out dir>/assets/ then goes to assets/persona/ and <out dir>/full/ to
asset_sources/persona/.
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from rembg import new_session, remove

SRC = Path(sys.argv[2] if len(sys.argv) > 2 else "src")
OUT = Path(sys.argv[3] if len(sys.argv) > 3 else "out")
OUT.mkdir(parents=True, exist_ok=True)
BASE = 140
DENSITIES = {"": 1.0, "1.5x": 1.5, "2.0x": 2.0, "3.0x": 3.0, "4.0x": 4.0}
MODEL = sys.argv[1] if len(sys.argv) > 1 else "isnet-general-use"

session = new_session(MODEL)


def cut(path: Path) -> Image.Image:
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

    # Harden the AI matte: its soft tail over the backdrop is haze.
    ai = np.clip((ai - 0.3) / 0.4, 0, 1)
    Image.fromarray((ai * 255).astype(np.uint8)).save(OUT / f"mask_{path.stem}.png")

    alpha = np.maximum(ai, ck)
    # Decontaminate only where the colour key decides (glows, sparkles):
    # the figure keeps its own (dark) colours.
    a = np.clip(alpha, 1e-3, 1)[..., None]
    fg = np.clip((rgb - (1 - a) * bg) / a, 0, 255)
    out_rgb = np.where((ck > ai)[..., None], fg, rgb)
    alpha[alpha < 0.02] = 0

    rgba = np.dstack([out_rgb, alpha * 255]).round().astype(np.uint8)
    im = Image.fromarray(rgba, "RGBA")

    ys, xs = np.nonzero(alpha > 0.03)
    x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
    return im, (x0, y0, x1, y1), bg


def square_crop(im: Image.Image, box) -> Image.Image:
    x0, y0, x1, y1 = box
    content = im.crop(box)
    side = int(max(x1 - x0, y1 - y0) * 1.02)
    sq = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    sq.paste(content, ((side - (x1 - x0)) // 2, (side - (y1 - y0)) // 2))
    return sq


for name, src in [("pivxie_public", "PIVXie_public.jpeg"),
                  ("pivxie_private", "PIVXie_private.jpeg")]:
    im, box, bg = cut(SRC / src)
    sq = square_crop(im, box)
    print(name, "backdrop", bg.round(), "content box", box, "square", sq.size)
    full = OUT / "full"
    full.mkdir(parents=True, exist_ok=True)
    sq.save(full / f"{name}.png", optimize=True)
    for folder, scale in DENSITIES.items():
        px = round(BASE * scale)
        d = OUT / "assets" / folder
        d.mkdir(parents=True, exist_ok=True)
        small = sq.convert("RGBa").resize((px, px), Image.LANCZOS).convert("RGBA")
        small.save(d / f"{name}.png", optimize=True)
    # Previews on light and dark cards.
    for tag, col in [("dark", (32, 26, 52)), ("light", (245, 245, 247))]:
        pv = Image.new("RGBA", sq.size, col + (255,))
        pv.alpha_composite(sq)
        pv.convert("RGB").resize((700, 700), Image.LANCZOS).save(OUT / f"preview_{name}_{tag}.png")
