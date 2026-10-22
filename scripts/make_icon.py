"""Draws the app icon: three ink bars (short, tall, short) on warm paper.

Apple's macOS template: an 824 px rounded square (superellipse) centred on a
1024 canvas with transparent margins; macOS 26 adds its own edge and shading.
Rendered at 4x and downsampled for clean edges at every size.

    python3 scripts/make_icon.py
"""
from pathlib import Path

from PIL import Image, ImageDraw

OUT = Path(__file__).resolve().parent.parent / "Verbatim/Resources/Assets.xcassets/AppIcon.appiconset"
SCALE = 4
CANVAS, BODY = 1024 * SCALE, 824 * SCALE
PAPER_TOP, PAPER_BOTTOM = (247, 245, 239), (237, 233, 223)
INK = (42, 41, 37)


def squircle_mask(size: int, exponent: float = 5.0) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    half = size / 2
    rows = []
    for y in range(size):
        dy = abs((y + 0.5 - half) / half)
        if dy >= 1:
            rows.append((0, 0))
            continue
        dx = (1 - dy ** exponent) ** (1 / exponent)
        rows.append((int(half - dx * half), int(half + dx * half)))
    draw = ImageDraw.Draw(mask)
    for y, (x0, x1) in enumerate(rows):
        if x1 > x0:
            draw.line([(x0, y), (x1, y)], fill=255)
    return mask


def master() -> Image.Image:
    body = Image.new("RGB", (BODY, BODY))
    draw = ImageDraw.Draw(body)
    for y in range(BODY):  # barely-there top-to-bottom warmth
        t = y / (BODY - 1)
        draw.line([(0, y), (BODY, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(PAPER_TOP, PAPER_BOTTOM)))
    width, gap = 0.095 * BODY, 0.072 * BODY
    heights = [0.26 * BODY, 0.476 * BODY, 0.26 * BODY]
    left = (BODY - (3 * width + 2 * gap)) / 2
    for i, h in enumerate(heights):
        x = left + i * (width + gap)
        top = (BODY - h) / 2
        draw.rounded_rectangle([x, top, x + width, top + h], radius=width / 2, fill=INK)
    icon = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    offset = (CANVAS - BODY) // 2
    icon.paste(body, (offset, offset), squircle_mask(BODY))
    return icon


def main() -> None:
    art = master()
    for px in (16, 32, 64, 128, 256, 512, 1024):
        art.resize((px, px), Image.LANCZOS).save(OUT / f"icon_{px}.png")
        print(f"icon_{px}.png")


if __name__ == "__main__":
    main()
