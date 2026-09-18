"""Make a ground texture tile: cross-fade each edge band with the opposite edge.

Why this works, in one line: a seam exists because the leftmost column does not match the rightmost.
Fading a narrow band on each edge toward its opposite makes those two columns *equal at the boundary*,
so the texture meets itself - at the cost of a slightly softer edge band, which at 16 pixels on a
1024 tile nobody will ever see.

What it does NOT do: invent detail, rotate, crop or resample. The middle of the art is untouched.

Usage:  python make_tileable.py <in.png> <out.png> [band_px]
"""

import sys
import os
import io

from PIL import Image


def seam_score(image: Image.Image) -> float:
    """How well the texture meets itself: the difference across the wrap seam against the same
    comparison in the middle. 1.0 means the seam is like any other pair of neighbouring columns."""
    width, height = image.size
    grey = image.convert("L")

    def column_gap(a: int, b: int) -> float:
        pa = list(grey.crop((a, 0, a + 1, height)).getdata())
        pb = list(grey.crop((b, 0, b + 1, height)).getdata())
        return sum(abs(x - y) for x, y in zip(pa, pb)) / float(height)

    return column_gap(0, width - 1) / max(0.001, column_gap(width // 2, width // 2 + 1))


def make_tileable(source: Image.Image, band: int) -> Image.Image:
    image = source.convert("RGB").copy()
    width, height = image.size
    band = max(1, min(band, width // 4, height // 4))

    # --- horizontal: fade the left band toward the right edge, and the right band toward the left
    left = image.crop((0, 0, band, height))
    right = image.crop((width - band, 0, width, height))
    for x in range(band):
        # The column at depth x pairs with the column at depth x from the OTHER edge - column 0 with
        # column W-1, column 1 with W-2 - because those are the two the wrap actually joins. The first
        # version paired each edge with the band beside it instead, thirty-one columns from the seam,
        # and made the seam worse: 4.85 became 7.18.
        #
        # Both edges get the same treatment, so at depth zero both become the same average and the
        # seam is equal by construction. t fades the change out across the band.
        t = 1.0 - (float(x) / float(band))
        opposite = width - 1 - x
        blended_left = Image.blend(image.crop((x, 0, x + 1, height)),
                                   image.crop((opposite, 0, opposite + 1, height)), t * 0.5)
        blended_right = Image.blend(image.crop((opposite, 0, opposite + 1, height)),
                                    image.crop((x, 0, x + 1, height)), t * 0.5)
        image.paste(blended_left, (x, 0))
        image.paste(blended_right, (opposite, 0))

    # --- vertical: the same, top against bottom
    top = image.crop((0, 0, width, band))
    bottom = image.crop((0, height - band, width, height))
    for y in range(band):
        t = 1.0 - (float(y) / float(band))
        opposite = height - 1 - y
        blended_top = Image.blend(image.crop((0, y, width, y + 1)),
                                  image.crop((0, opposite, width, opposite + 1)), t * 0.5)
        blended_bottom = Image.blend(image.crop((0, opposite, width, opposite + 1)),
                                     image.crop((0, y, width, y + 1)), t * 0.5)
        image.paste(blended_top, (0, y))
        image.paste(blended_bottom, (0, opposite))
    return image


def main() -> None:
    source_path, out_path = sys.argv[1], sys.argv[2]
    band = int(sys.argv[3]) if len(sys.argv) > 3 else 16
    base = Image.open(source_path)
    fixed = make_tileable(base, band)
    fixed.save(out_path)

    before = seam_score(base)
    after = seam_score(fixed)
    print("%-34s seam %.2f -> %.2f  (band %d px)" % (os.path.basename(source_path), before, after, band))

    # The proof a person can look at: three by three, so every seam in it is the one that was broken.
    width, height = fixed.size
    preview = Image.new("RGB", (width * 3, height * 3))
    for row in range(3):
        for col in range(3):
            preview.paste(fixed, (col * width, row * height))
    preview = preview.resize((600, 600), Image.LANCZOS)
    preview.save(out_path.replace(".png", "_tiled3x3.png"))


main()
