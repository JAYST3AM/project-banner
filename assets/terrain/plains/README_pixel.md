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
- Their edges do not meet themselves (seam ratio 4.9-6.2, against 0.0 for the tileset fills), so a
  repeat shows a line. The shader already fights that three ways: four variants per look, a
  per-repeat offset so the same motif never lands on the same grid, and a soft blend between looks.
  If it still reads on the map, the fix is to mirror each tile into a 2048 sheet, which is seamless
  by construction.
- They are high-contrast and saturated; at map zoom that reads as busy rather than calm. A larger
  repeat helps.
