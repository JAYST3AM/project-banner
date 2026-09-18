# Terrain art

Source art for the campaign map's biomes and the props that stand on them. One folder per biome:

```
assets/terrain/
  grass/    grass_ground.png           (the tileable ground)
  forest/   forest_ground.png  pine_large.png  pine_small.png  bush.png
  rock/     rock_ground.png    boulder_large.png  boulder_small.png
  props/    shared props that belong to no single biome (a fence post, a cart)
```

**`data/terrain/biomes.json` is the catalogue and the only source of truth.** The generator reads
it, never a folder listing: a file that is not named in the catalogue is not used, and an entry
whose file is missing is a logged error rather than a silent nothing. Every biome entry records its
ground file, its palette, its height character, and its props with a density and a minimum weight,
so a blend at 30% forest grows 30% as many trees and none at all below the weight the entry names.

Two rules that keep it honest:

- **Naming: `<thing>_<size>.png`, lowercase, no spaces.** Files are sorted by looking at them if the
  names do not say, but a name that says is worth a minute of whoever exports it.
- **Licences.** Art that may not be redistributed goes in `assets/art_source/` (gitignored) and is
  copied in at import time, as the 3D character sheets already are. Art that may be - generated
  key art, commissioned work - lives here and is committed.
