# Terrain

The owner's direction for ground, decided in conversation. Nothing here is built beyond the first
showing unless a line says so.

## The shape of it

- **The campaign map owns terrain.** A battlefield is a *window of it* - biome, height trend, line
  features - with local detail invented inside those facts. A battle carries its coordinates and
  its weather today; it does not carry its ground. `BattleContext` is the channel that would.
- **Biomes blend; they do not abut.** A tile carries weights (70% grass / 30% forest), and colour,
  height, prop density and movement all read those weights. Heights must blend too, or the border
  becomes a cliff.
- **Props follow the weights**, each with its own base density and a **minimum weight**, placed from
  a seeded source so a tile always grows the same trees. A sprinkle of woodland should not leave
  lone trees standing in a field.
- **Movement in a mixed tile is by the mix**, not by the dominant biome. *Decided.*
- **Blend width and border shape are untested.** One tile reads as a drawn border, two or three as a
  landscape; a straight blend still reads as a straight line. Both are constants in
  `world_terrain.gd`, waiting on a look.

## Art

- **Four looks per biome, and four sub-variants inside each look** - sixteen grounds in total.
  Lush is not one texture but four that look the same and differ slightly, which is what stops the
  repetition being visible once a player has crossed the map a few times.
  - *Which look* a tile uses should come from the world (moisture, wear, region, season - the same
    field that decides the biome), and *which sub-variant* from a seeded hash of the tile's position
    so a tile always shows the same one and neighbours rarely match.
  - Sixteen 1254-pixel grounds is roughly 90 MB uncompressed, so they want VRAM compression at
    import: a real constraint, and the reason to settle the naming (`plains_lush_1..4.png`) before
    the art is made rather than after.
- Props: trees, rocks, bushes, reeds - density from the weights, not from a separate pass.
- **Delivered:** the plains set - Standard, Lush, Dry, Worn. Painted, top-down, 1254x1254, tileable.
  Catalogued in `data/terrain/biomes.json` with palettes sampled from the art.
- **Standing requirement: four looks in use, not two.** The first showing mixed the set's first look
  against its third because one biome had to stand in for two; that is a placeholder, not the plan.

## What the first showing proved

- A biome field from the world seed, a shader mixing two grounds by its weight, and a blend band
  across the map: **built, and the owner's verdict was "you've meshed it very well."**
- Field generation: 160x112 in ~296 ms, once, at load. Zero cost per frame. GDScript noise is the
  bill; the native kernel or a compute pass is the way to cut it if it ever needs cutting.
- Smaller tiles need **mipmaps** under the samplers, or a 1254-pixel painting shrunk a quarter
  aliases into coloured speckle. Tile size 800 -> 260 was written with mipmaps enabled and is
  uncommitted, awaiting the owner's decision.

## Still open

- **The map's own feature layer is missing over the ground** - roads, settlement circles, labels,
  parties. Draw order was ruled out by reading (terrain z -1, feature pass z 0; the code is intact).
  The owner's hypothesis is that the terrain is drawn on top of the interface. One run with the
  ground off settles it.
- Terrain affecting the fight, beyond movement: line of sight, formation breaking, archers on a
  ridge. The hook exists; nothing reads it.
