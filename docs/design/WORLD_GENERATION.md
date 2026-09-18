# World generation, streaming and the running world

The owner's direction. Talked through; not built. His questions were whether the whole map - towns,
forts, cities and castles included - can be procedural, built off-screen around the player's view,
with factions and armies still moving while nobody is looking.

## Decided

- **The map is endless.** Not finite. What that costs in frames, gameplay and AI is below.
- **All four simulate**: parties, factions, economy **and** culture.
- **Streaming must be invisible.** The player should never see the map rendering while travelling:
  it is always built ahead of them. And what is not in view is reduced to data, to save frames.
- Carried over from the terrain conversation: the campaign map owns terrain, a battlefield is a
  window of it, and biomes blend by weight.

## The split everything rests on

**The world is data, complete and deterministic from the seed. Only the picture streams.**

- **Generation happens by *position and seed*, never by *when the player looked*** - otherwise the
  world differs according to where someone wandered, and saves and determinism both break. A save
  becomes the seed plus whatever has changed: small, and exact on load.
- **Settlements are sites before they are buildings.** The terrain proposes sites - a river
  crossing, a hilltop, a coast - and rules turn a site into a town, fort or castle from its faction,
  its region and its age. Each site's layout comes from its own seed, so the same town always looks
  the same and can be entered, which is what the settlement screens already do.
- **The simulation never cares what is drawn, and off-screen is never frozen.** A world that exists
  only where the player is looking is not a world.

## Endless, and what it actually costs

- **Frames: nothing special.** Endlessness is a huge coordinate space with chunks generated from a
  positional hash; no memory is spent on ground nobody has visited. Chunked and view-streamed, an
  endless map costs what a large finite one costs.
- **The simulation is the real cost, and it is solved by not running everywhere.** Regions are
  simulated in full near the player and **lazily caught up** elsewhere: each region remembers when it
  was last simulated, and when the player returns it is advanced in one step by the time that passed.
  An army that was marching three days ago is now three days down its road - because its position is
  a function of time, not the sum of thousands of ticks.
- **AI and NPCs carry schedules, not steering.** An off-screen party holds a route and an arrival
  time; a faction holds a queue of dated intentions ("besiege X on day 12"). Nothing needs a
  per-frame update to keep moving, and nothing freezes when it leaves the screen.
- **Gameplay: infinite ground means conquest has no end**, so what makes the world matter has to be
  local - reputation, supply, season, the region underfoot - while the far world is texture. Borders
  still exist, as fronts rather than as walls.

## Streaming, and how "never seen" is achieved

- **A pre-render ring in front of the camera**, sized by travel speed rather than by the screen: two
  or three screens of ground built *ahead*, because a camera crosses ground faster than a queue can
  build it. That margin is what makes it invisible; raw speed is not.
- **Three rings of detail**: full (mesh, props, buildings), coarse (flat ground, labels), and
  **unloaded - data only**. Meshes and props are freed when out of view; the arrays stay, because
  they are kilobytes and the simulation needs them.
- **Built to a time budget, not a chunk count**: about two milliseconds a frame off a priority queue,
  so a heavy chunk cannot become a hitch.
- **Hysteresis and a short keep-warm**: a chunk that has just left view stays a few seconds, so a
  player pacing back and forth does not thrash the builder.

## What already exists to build on

The world seed; deterministic positional hashing (the same rule the battlefield terrain and the biome
field already use); `WorldBuilder`, which currently builds four settlements; the party and overworld
services, which already spawn and move parties - and already move them by *arrival time*, which is
the shape the lazy catch-up needs. An extension of that path, not a rewrite.

## Open

1. Whether the coarse catch-up may **invent** outcomes (a battle between two off-screen armies), or
   whether such things resolve the moment they are next observed.
2. Chunk size - and therefore what a "region" is for simulation purposes.
3. How the player's own region is defined while travelling: a radius, or the region they stand in.
