# What still has to be built

Everything talked through and not yet done, shortest honest form. The detail lives in
`TERRAIN.md` and `WORLD_GENERATION.md`; this is the single list to read instead of both.

## Waiting on the owner

- **The 30 Hz contact fix** - the solver's step cap does not scale with the clock, so contact loosens
  at thirty. One line; offered, not taken.
- **Individual-soldier targeting** - unit-level attack orders already work. Aiming at one man in a
  formation is a new feature and his pick.
- **The next biome's art** - plains is in and meshing; the second biome is what a real blend needs.
- **What two off-screen armies do when they meet** - resolved at observation, or invented by the
  catch-up. His call.

## The world, in the order it wants building

1. **Chunked streaming** - the world in chunks, three rings of detail, a time budget, a coarse
   fallback so a missing chunk is never a hole, and keep-warm so turning around does not thrash.
2. **Periodic noise** - the wrapping world needs a lattice whose period is the world's size, or the
   map meets its own beginning with a seam.
3. **Sites to settlements** - the terrain proposes sites, rules make them towns, forts and castles,
   each layout from its own seed.
4. **Lazy catch-up** - regions remember when they were last simulated and advance by the elapsed
   time when seen again. Positions as functions of time, not sums of ticks.
5. **Factions, economy, culture** - the three that keep living while nobody watches.
6. **Parties on schedules** - a route and an arrival time rather than steering. The travel service
   is already shaped this way.
7. **Battlefield as a window** - a battle's ground is cut from the campaign map where the fight
   happens, and belongs to one biome, not several.

## The army

- **Messengers and the news window** - events reach the player only if somebody carries word. The
  window shows what arrived and when, and nothing arrives without a messenger.
- **Staff roles** - cook, quartermaster, messenger, filled from a soldier's skills and traits or
  hired in a settlement. Each role moves a number the player feels.

## The battle

- **The migration's remaining steps** - the combat model is on the compute path; still to come are
  the campaign driving a battle, the command UI, promotion to base game, and the CPU version
  archived as the oracle. `docs/BATTLE_MIGRATION_PLAN.md`.
- **Pre-battle flow** - picking formations, placing them and grouping them before the fight, which
  is what the small scales exist to test.
- **Hero close-ups** - 2D for the ranks, 3D for a commander when the camera goes in.

## Ground detail

- **Props** - trees, rocks, worked fields - placed by the same field that decides the look, with a
  minimum so no bare patch is left without them.
- **Height that displaces** - the height channel shades today; later it lifts the ground.
- **Map ink polish** - a soft darkening under labels, the way maps do it, as a belt-and-braces
  guarantee of legibility over any ground.
