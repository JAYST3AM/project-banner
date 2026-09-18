# World generation, streaming and the running world

The owner's direction, talked through and not yet built. The question he asked was whether the whole
map - towns, forts, cities and castles included - can be procedural, built off-screen around the
player's view, with factions and armies still moving while nobody is looking.

## The split everything rests on

**The world is data, complete and deterministic from the seed. Only the picture streams.**

- **Generation happens once, in data**, for the whole map: every cell, every settlement site, every
  faction's start. It is arrays, not meshes, so it is cheap whether or not anyone looks.
- **The picture streams around the camera**, in three rings: full detail (mesh, props, buildings),
  then coarse (flat ground, name labels), then nothing but data. A few tiles per frame, dropped
  behind the player, with hysteresis at the boundary so tiles do not thrash.
- **The simulation never cares what is drawn.** Factions and armies move in data space on a coarse
  tick - once per in-game hour, not per frame. **Off-screen is not frozen.** A world that exists
  only where the player is looking is not a world, and the first time a war only starts when
  somebody watches it, the illusion is gone for good.
- **Settlements are sites before they are buildings.** The terrain proposes sites - a river
  crossing, a hilltop, a coast - and rules turn a site into a town, fort or castle from its faction,
  its region and its age. Each site's layout comes from its own seed, so the same town always looks
  the same and can be entered, which is what the settlement screens already do.
- **The trap: never generate a castle, a lord or a war when the player first looks.** Generate by
  *position and seed*, never by *when you looked*, or the world differs according to where the
  player wandered and both saves and determinism break. A save then becomes the seed plus what has
  changed - small, and exact on load.

## What already exists to build on

The world seed; deterministic positional hashing (the same rule the battlefield terrain and the
biome field already use); `WorldBuilder`, which currently builds four settlements; the party and
overworld services, which already spawn and move parties. This is an extension of that path, not a
rewrite.

## Decisions the owner has not made yet

1. **Finite or endless map.** Lean: finite. Wars and factions need edges, and edges make places
   matter.
2. **What simulates off-screen**: parties and factions only, or economy, culture and weather too?
3. **Streaming radius and hitch budget**: how many tiles a frame are we willing to pay for.
