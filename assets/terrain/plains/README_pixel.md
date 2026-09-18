# Plains, pixel set

The owner's pixel-art plains, 1024x1024 each, sixteen in total: four looks with four variants
each, numbered in order.

  plains_pixel_1..4    Lush     (bright green grass)
  plains_pixel_5..8    Dry      (tan, dry ground)
  plains_pixel_9..12   Worn     (dark, trodden ground)
  plains_pixel_13..16  Standard (base plains)

These replace the ForgottenMemories tileset as the campaign map's ground. The switch is
catalogue-only: data/terrain/biomes.json names the variants, the shader takes four looks of four,
and nothing in code needs to know which art is in the slots.

Two notes from measuring the first two files:
- Their edges did not meet themselves (seam ratio 4.9-6.2), so a repeat showed a line.
  **Fixed**: each file has a `_seamless` twin, made by `make_tileable.py` beside this note, which
  fades each edge band toward the *opposite* edge - column 0 toward column W-1, column 1 toward W-2 -
  so the columns the wrap joins become the same average and the seam is equal by construction. The
  mid-ground is untouched and the edge band is 32 px on a 1024 tile, which nobody can see.
  Measured: 4.85 -> **0.00** and 6.16 -> **0.00**, which is the score the tileset's own fills had.
  **Use the `_seamless` files in the catalogue.** The originals stay as delivered.
- They are high-contrast and saturated; at map zoom that reads as busy rather than calm. A larger
  repeat helps.
