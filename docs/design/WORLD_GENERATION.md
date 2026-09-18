# World generation, streaming and the running world

The owner's direction. Talked through; not built. His questions were whether the whole map - towns,
forts, cities and castles included - can be procedural, built off-screen around the player's view,
with factions and armies still moving while nobody is looking.

## Decided

- **The world is gigantic and wraps.** Walking or sailing one way far enough brings you round to
  where you started: the illusion of a globe. There is a limit, but the player should never
  meaningfully reach it.
- **All four simulate**: parties, factions, economy **and** culture.
- **Streaming must be invisible**: no freeze while a chunk loads, and never a black screen.
- **News travels by messenger.** What happens in the world reaches the player only if somebody
  carries word of it - and staff roles are a later layer of the same idea (messengers now,
  quartermasters and cooks later).
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
- **Off-screen is never frozen.** A world that exists only where the player is looking is not a
  world.

## The wrapping world

- Walking far enough in one direction returns you where you started: coordinates wrap and the local
  view never has to know. On the ground it reads as a globe; the map is a torus, which is the
  flat-land version of "there is no edge".
- **The requirement that makes it seamless:** the noise and the biome field must be **periodic** -
  sampled on a lattice whose period is the world's size. A non-periodic field meets its own
  beginning with a visible seam, and that is the one artefact a wrapping world cannot hide.
- **What it costs:** a modulo in the chunk index, and nothing else. With a bonus: on a wrapping
  world every distance is bounded - no two places are more than half a world apart - so the lazy
  catch-up can never accumulate unbounded state.
- **What it changes in play:** circumnavigation becomes a real journey, trade can go the long way
  round, and "the world is round" can be something a player discovers rather than is told.

## Travel across new ground, and what it actually costs

- **The cost is the rate at which the player crosses *new* ground, not the size of the world.** An
  endless map costs nothing in total, and leaving ground that has already been generated is the same
  arithmetic in reverse - a chunk is freed. What matters is that new chunks are built faster than
  the player reaches them, and the gap there is enormous: a chunk is roughly two milliseconds of
  work, a rider crosses one in about a minute.
- **The simulation is the real cost, and it is solved by not running everywhere.** Regions simulate
  in full near the player and are **lazily caught up** elsewhere: each region remembers when it was
  last simulated, and is advanced in one step by the time that passed. An army three days down its
  road is three days down its road because its position is a function of time, not the sum of
  thousands of ticks. **The bar is believability** - arrivals on roads, no teleporting, outcomes a
  player would accept - not simulation purity.
- **AI and NPCs carry schedules, not steering.** An off-screen party holds a route and an arrival
  time; a faction holds a queue of dated intentions ("besiege X on day 12"). Nothing needs a
  per-frame update to keep moving, and nothing freezes when it leaves the screen.
- **Gameplay: what makes the world matter has to be local** - reputation, supply, season, the region
  underfoot - while the far world is texture. Borders become fronts rather than walls.

## News, and who carries it

- Events in the world - a siege, a harvest, a death, an army on the move - are timestamped where
  they happen and reach the player as **news**, not as truth.
- **Without a messenger the player knows only what he can see.** With one, word arrives with a delay
  that is a function of distance and speed: three days after the siege began, not during it.
- This falls out of the design rather than being bolted on: the catch-up already timestamps events,
  so the only new thing is the carrier.
- **Staff are soldiers with the right skills and traits, or people hired in a settlement.** *Decided.*
  A man in the party can be made the messenger, the cook or the quartermaster - the traits and skills
  the settlement screen already shows are what decide who is worth appointing - and the same people
  can be hired in a town.
- Every staff role is the same shape: a quartermaster changes what supply reaches the army, a cook
  changes what the men eat, a messenger changes what the player knows and when. Each is a person the
  army has or lacks, and each moves a number the player feels.

## Streaming, and how "never seen" is achieved

- **A pre-render ring in front of the camera**, sized by travel speed rather than by the screen: two
  or three screens of ground built *ahead*. That margin is what makes it invisible; raw speed is not.
- **Three rings of detail**: full (mesh, props, buildings), coarse (flat ground, labels), and
  unloaded - data only. **The coarse ring is the fallback**: if a chunk is not built yet the player
  sees coarse ground and a label, never a hole and never a black screen.
- **Built to a time budget, not a chunk count**: about two milliseconds a frame off a priority
  queue, so a heavy chunk cannot become a hitch.
- **Hysteresis and a short keep-warm**: a chunk that has just left view stays a few seconds, so a
  player pacing back and forth does not thrash the builder.
- **Acceptance criterion, in the owner's words**: no freeze on a chunk load, no black screen while
  loading, and a **consistent frame rate with no jitter**. Jitter is the harder half: a budget that
  is spent unevenly shows as stutter even when the average is good, so the per-frame work is capped
  and spread rather than run to completion as fast as it can go.

## What already exists to build on

The world seed; deterministic positional hashing (the same rule the battlefield terrain and the biome
field already use); `WorldBuilder`, which currently builds four settlements; the party and overworld
services, which already spawn and move parties - and already move them by *arrival time*, which is
the shape the lazy catch-up needs. An extension of that path, not a rewrite.

## Open

1. ~~Whether the coarse catch-up may invent outcomes.~~ **Decided: it may invent them.** Two
   off-screen armies that meet are resolved by the catch-up, not left waiting for an observer. The
   bar stays the one above - believable, not pure - so an invented result has to be one a player
   would have accepted had they watched it.
2. Chunk size - and therefore what a "region" is for simulation purposes.
3. How the player's own region is defined while travelling: a radius, or the region they stand in.
4. When messengers arrive, and what they cost.
