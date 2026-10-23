#!/usr/bin/env python3
"""Draw the drag-to-Applications backdrop for the Renvert disk image."""
from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

WIDTH = 660
HEIGHT = 400
SCALE = 2
BACKGROUND = (15, 20, 21)
ARROW = (33, 170, 190)
CAPTION = (154, 176, 178)
MUTED = (110, 128, 130)


def font(size: int) -> ImageFont.ImageFont:
    for path in (
        "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
    ):
        if Path(path).exists():
            return ImageFont.truetype(path, size * SCALE)
    return ImageFont.load_default()


def draw() -> Image.Image:
    image = Image.new("RGB", (WIDTH * SCALE, HEIGHT * SCALE), BACKGROUND)
    pen = ImageDraw.Draw(image)
    y = 188 * SCALE
    x0 = 268 * SCALE
    x1 = 392 * SCALE
    thickness = 4 * SCALE
    pen.line((x0, y, x1 - 22 * SCALE, y), fill=ARROW, width=thickness)
    head = 14 * SCALE
    pen.polygon(
        [(x1 - head * 2, y - head), (x1, y), (x1 - head * 2, y + head)],
        fill=ARROW,
    )

    primary = font(15)
    secondary = font(12)
    lines = (
        (primary, "Перетащите в папку «Программы»", CAPTION, 318),
        (secondary, "Drag into Applications", MUTED, 344),
    )
    for face, text, color, baseline in lines:
        box = pen.textbbox((0, 0), text, font=face)
        text_width = box[2] - box[0]
        pen.text(((WIDTH * SCALE - text_width) / 2, baseline * SCALE), text, font=face, fill=color)
    return image


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: make_dmg_background.py background.png background@2x.png")
    image = draw()
    image.save(sys.argv[2], "PNG")
    image.resize((WIDTH, HEIGHT), Image.Resampling.LANCZOS).save(sys.argv[1], "PNG")


if __name__ == "__main__":
    main()
