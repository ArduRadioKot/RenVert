#!/usr/bin/env python3
"""Builds the app icon, the in-app brand mark and the menu bar template from logoR.png.

The source is small, so the background is upscaled smoothly while the letter R is
rebuilt from its mask at full resolution to keep its edges crisp.
"""
from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "logoR.png"
ASSETS = ROOT / "Sources/Renvert/Assets.xcassets"

LETTER = (33, 170, 190)
BACKGROUND = (15, 20, 21)
TILE = 824  # Apple's macOS icon grid: an 824pt tile centered on a 1024pt canvas.
CORNER = 0.225


def letter_mask(img: Image.Image) -> Image.Image:
    rgb = img.convert("RGB")
    mask = Image.new("L", rgb.size, 0)
    src, dst = rgb.load(), mask.load()
    for y in range(rgb.height):
        for x in range(rgb.width):
            r, g, b = src[x, y]
            # Letter pixels are cyan; antialiased edges blend toward the dark tile.
            if b > g * 0.9 and b - r > 40:
                dst[x, y] = max(0, min(255, int((b - BACKGROUND[2]) / (LETTER[2] - BACKGROUND[2]) * 255)))
    return mask


def sharpen_mask(mask: Image.Image, size: int) -> Image.Image:
    big = mask.resize((size, size), Image.BICUBIC).filter(ImageFilter.GaussianBlur(size / 300))
    return big.point(lambda v: max(0, min(255, (v - 128) * 6 + 128)))


def fill_from_neighbors(img: Image.Image, hole: Image.Image) -> Image.Image:
    """Replaces masked pixels with a weighted average of the surrounding unmasked ones."""
    keep = hole.point(lambda v: 255 - v)
    known = Image.composite(img, Image.new("RGB", img.size), keep)
    result = img.copy()
    out, h = result.load(), hole.load()
    pending = {(x, y) for y in range(img.height) for x in range(img.width) if h[x, y]}
    # Small radii keep nearby detail; larger ones reach pixels deep inside the letter strokes.
    for radius in (2, 4, 8, 16):
        w = keep.filter(ImageFilter.GaussianBlur(radius)).load()
        c = known.filter(ImageFilter.GaussianBlur(radius)).load()
        for x, y in list(pending):
            if w[x, y] > 8:
                out[x, y] = tuple(min(255, v * 255 // w[x, y]) for v in c[x, y])
                pending.discard((x, y))
    for x, y in pending:
        out[x, y] = BACKGROUND
    return result


def rounded(size: int, radius_ratio: float = CORNER) -> Image.Image:
    scale = 4
    big = Image.new("L", (size * scale, size * scale), 0)
    ImageDraw.Draw(big).rounded_rectangle(
        (0, 0, size * scale - 1, size * scale - 1), radius=size * scale * radius_ratio, fill=255
    )
    return big.resize((size, size), Image.LANCZOS)


def build_tile(size: int) -> tuple[Image.Image, Image.Image]:
    """Returns the rounded tile and the full-resolution letter mask."""
    src = Image.open(SOURCE).convert("RGBA")
    src = src.crop(src.getbbox())
    side = max(src.size)
    square = Image.new("RGBA", (side, side), (*BACKGROUND, 255))
    square.paste(src, ((side - src.width) // 2, (side - src.height) // 2), src)
    # Fill the transparent corners so upscaling doesn't pull dark fringes inward.
    flat = Image.new("RGBA", square.size, (*BACKGROUND, 255))
    flat.alpha_composite(square)

    mask = letter_mask(flat)
    erase = mask.filter(ImageFilter.MaxFilter(3)).point(lambda v: 255 if v > 0 else 0)
    background = fill_from_neighbors(flat.convert("RGB"), erase).resize((size, size), Image.LANCZOS)

    letter = Image.new("RGB", (size, size), LETTER)
    tile = Image.composite(letter, background, sharpen_mask(mask, size)).convert("RGBA")
    tile.putalpha(rounded(size))
    return tile, sharpen_mask(mask, size)


def build_icon(tile: Image.Image) -> Image.Image:
    canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    offset = (1024 - TILE) // 2
    shadow = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    shadow_alpha = Image.new("L", (1024, 1024), 0)
    shadow_alpha.paste(rounded(TILE), (offset, offset + 12))
    shadow.putalpha(shadow_alpha.filter(ImageFilter.GaussianBlur(14)).point(lambda v: int(v * 0.35)))
    canvas.alpha_composite(shadow)
    canvas.alpha_composite(tile, (offset, offset))
    return canvas


def save(img: Image.Image, path: Path, size: int) -> None:
    img.resize((size, size), Image.LANCZOS).save(path)


def main() -> None:
    tile, mask = build_tile(TILE)
    icon = build_icon(tile)

    appicon = ASSETS / "AppIcon.appiconset"
    for base in (16, 32, 128, 256, 512):
        save(icon, appicon / f"icon_{base}x{base}.png", base)
        save(icon, appicon / f"icon_{base}x{base}@2x.png", base * 2)

    brand = ASSETS / "BrandMark.imageset"
    save(tile, brand / "mark.png", 256)
    save(tile, brand / "mark@2x.png", 512)

    # Template glyph for the menu bar: the letter alone, trimmed and padded to a square.
    glyph = mask.crop(mask.getbbox())
    side = int(max(glyph.size) * 1.08)
    square = Image.new("L", (side, side), 0)
    square.paste(glyph, ((side - glyph.width) // 2, (side - glyph.height) // 2))
    menubar = ASSETS / "MenuBarMark.imageset"
    for px, name in ((18, "r-18.png"), (36, "r-36.png")):
        alpha = square.resize((px, px), Image.LANCZOS)
        out = Image.new("RGBA", (px, px), (0, 0, 0, 0))
        out.putalpha(alpha)
        out.save(menubar / name)


if __name__ == "__main__":
    main()
