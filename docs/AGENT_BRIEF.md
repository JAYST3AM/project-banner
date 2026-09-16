# Project Banner — agent brief

**Read this before directing any work on this project.** It is written for an agent that has no
history with the repository: the game, its vision, its end goals, the rules that must not be broken,
how work is verified, and what is currently in flight.

---

## 1. What the game is

**Project Banner** — a medieval sandbox strategy RPG. Three layers:

1. **A world map** the player travels: settlements, hostile bands, a clock, a party.
2. **Persistent individual soldiers.** Every soldier is a person with a name, age, traits, level,
   kills, battles survived and a personal history log. They are recruited, they fight, they die,
   and they are not interchangeable.
3. **Tactical battles** on generated terrain, fought by formations — the same engine for both
   sides, with results written back to those individual soldiers.

- Engine: **Godot 4.7.2-stable**, typed GDScript (tabs, `##` doc comments).
- Repo: `JAYST3AM/project-banner` (public). Project root: `F:\VSC Projects\Project Banner`.
- Save format is versioned with a migration path; a save from a newer build is refused.

## 2. The vision

The standing design principle, quoted from the project's own roadmap:

> Individual soldiers should feel like people rather than numbers. `Soldier` already carries the
> fields this needs — age, traits, loyalty, level, kills, battles survived, and an open-ended
> `history` log. The systems that fill that log come later; the storage for it exists now so those
> systems never have to retro-fit identity onto a stat block.

The three ambitions that follow from it:

- **Battles that get genuinely large.** Twenty thousand soldiers a side is the goal. It is
  currently **0.2 ticks a second** at that size — a goal, not a result — and this project's
  culture is to say so rather than imply otherwise.
- **A living world.** Caravans, patrols, lordly armies, trade, settlement production.
- **Battles you can read while they happen.** The owner's own instruction: *"a formation as a
  single entity, not a bunch of units in a formation"* — the player sets the structure before the
  battle, and can break it down as far as a single soldier. The display half of that is built; the
  simulation half is the first slice only (see §5).

## 3. End goals, in the project's own order

From the roadmap's post-checkpoint list, roughly by how much each leans on what exists:

1. **Combat depth** — formations as fighting styles, spears, archery and projectiles, cavalry,
   shields, weapons, armour, fatigue, wounds, morale effects.
2. **Soldier depth** — equipment, inventory, upgrade trees, named captains, traits that do things,
   loyalty, aging, permadeath, personal history surfaced back to the player.
3. **Battlefield** — terrain consequences, procedural battlefields, weather, sieges.
4. **Overworld life** — AI parties, caravans, trade, production, supply and demand, world events.
5. **Grand strategy** — faction ownership, lords, armies, wars, diplomacy, territory, castles,
   prisoners, mercenaries, kingdom creation.
6. **World generation** — procedural map and political simulation.

Milestones 0 through 7.8c of the engineering track are **done** (world, soldiers, battles,
persistence, then a long run of pure-performance milestones). The vertical slice has been complete
and restart-safe for some time.

## 4. The rules that must not be broken

**Architecture invariants (each one is guarded by tests):**

- A soldier's identity lives in `CampaignState.soldiers` and nowhere else. `Party` stores **ids**.
  Battle units hold a `soldier_id`, never a `Soldier`.
- `BattleContext` is the only channel between campaign and battle. The battle scene never reads
  `GameManager.campaign` or a catalog.
- A battle is described (`BattleResolver.build_result`) before it is applied (`apply()`), and
  `apply()` is the only function in the project that lets a battle change the campaign.
- Autoload scripts must NOT declare `class_name` (it collides with the singleton).
- Time conversion lives only in `CampaignClock`.
- Balance numbers live in `data/*.json`, never hardcoded.

**Engineering rules:**

- **Step 7.8 is locked** — the overlap optimisation and the milestone tip must not be altered.
  Work that follows builds on it, and any claimed regression must be measured against it.
- **Instrument before you optimise, and count what the code does** — not only how long it takes.
  Several milestones in this repository exist solely because a counter said the work was being done
  far too often, rather than being slow.
- **Measure before believing, and prefer an equivalence proof to an argument.** Where behaviour has
  been deliberately changed, say so explicitly and test the physical invariants.
- **No solving a problem with a hack**: no teleporting, no auto-kill, no declared winner, no
  widening a reach to make a fight resolve, no disabling formation behaviour, no loosening the
  separation pass, no hidden timeout that resolves a battle.
- **Every milestone lands with tests that would fail if it broke**, the full suite green, the
  restart check green, and the four docs updated in the same commit (`CURRENT_STATE.md`,
  `ROADMAP.md`, `GAME_ARCHITECTURE.md`, `DECISIONS.md`).
- **A dev-only counter or probe is deleted or switched off by default** before a milestone lands.

## 5. Where it is right now

**Verified:** 26 suites / 8,936 assertions / 0 failures headless, and a two-process restart check.

**Committed and audited on `main`:** `b9d3bcc` (gameplay and view: groups move as one / D-108,
right-click travel / D-109, an honesty pass on the settlement panel, per-suite save isolation in
`user://saves_test`, arrows and correctly-sized damage numbers, a block view for formations, terrain baked
into one draw call), `e7b55d2` (a Godot tool that bakes a rigged 3D model into 8-direction sprite sheets),
the milestone pair (the kill cleanup, measured at 98.3% of a tick and then made **104×** cheaper / D-110
and D-111), then `c0ab486` (Step 7.11: the per-soldier loop counted by path and priced by operation /
D-112) and `d1f47ab` (Step 7.12: the loop's calls removed - the per-body press-forward gate, the native
mirror's guard, the terrain path / D-113 and D-114). The Step 7.13 slice that carries this brief is the
formed-soldier focus fast path (D-115), and the turning-body transform was measured, priced and abandoned
before anything was built on it. Step 7.8's separation pass is locked and untouched.

**Measured next bottlenecks** (from the repository's own profiles — these are the honest candidates
for the next engineering milestone):

- The **per-soldier update loop**: **under active work**. Step 7.11 priced it; Step 7.12 removed the calls
  it found - the press-forward gate, the native mirror's guard and the terrain path - taking the soldiers
  phase at 20,000 soldiers **from 204.4 ms to 169.4 ms** and the tick from about 400 ms to about 363 ms,
  each change measured as a paired run with its reference kept in the build behind a switch. Step 7.13 has
  started on the **other** large phase: the formed-soldier focus fast path took the target phase from
  72.1 ms to 56.4 ms and the soldiers phase to **154.5 ms**, proved by a per-tick identity test rather
  than an argument.
- **The body transform is abandoned, and its numbers stay in the record.** The lattice claim was verified -
  a body's slot lattice is an exact anchor-centred rigid transform of the previous tick's, worst error
  1.7e-5 over 80,000 samples - and then priced for coverage before anything was built on it: at the game's
  own arrival epsilon only **1.4 per cent** of soldier-ticks are on a body whose facing changed, which is
  the only case the existing rigid step path does not already cover. About a millisecond a tick is not
  worth a change to the most sensitive path in the game.
- **The native mirror batch** is still the next boundary-crossing win: one crossing a tick instead of
  twenty thousand, which needs a method on the C++ side and work against D-095.
- **The target-phase instrument costs what it measures - and it is now measured.** That loop carries
  per-soldier `Time.get_ticks_usec()` pairs; gating them behind `PB_TGT_TIMING=off` shows the instrument
  costs about **6.3 ms a tick** at this size (the whole tick 352.6 ms instrumented against 346.3 ms with
  the timers off). Every paired delta in this project stays sound because both halves carry the same
  instrument, but the absolute tick is lower than quoted, and the game never profiles. See D-116.
- **Target selection** was where Step 7.12 stopped and Step 7.13 begins; Step 7.8's formation-driven
  engagement work had already reduced it 79 per cent before either. Its remaining named items at 20,000
  are `focus` (15.4 ms, down from 26.8), `retained` (8.5 ms) and about 32 ms of loop work the counters do
  not yet name.
- **Rendering at scale is not in any of the simulation measurements** — the benchmark steps the
  simulation directly. Drawing twenty thousand soldiers is a separate problem nobody has paid for; a
  render-path spike exists in the tree but is deliberately uncommitted.

The kill cleanup used to stand first on this list as a **suspected O(deaths × army)** walk in
`BattleSimulator._attack()`. It is no longer suspected: Step 7.9 measured it at 98.3% of a
mass-casualty tick, and Step 7.10 replaced it with a per-tick order index that clears the same orders
104× cheaper (D-110, D-111). The baseline is reproducible from this tree with
`res://scenes/dev/death_storm_probe.tscn --cleanup=walk`, the shipped chain is what the probe measures by
default, and `--cleanup=both` runs the reference and the chain over one setup and asserts they release
the same soldiers.

**Other work in flight, not a milestone:**

- **Artwork.** Known limitation #14 is "no artwork" — because there is none. The *pipeline* is now in
  the repository: `e7b55d2` adds a Godot tool that bakes a rigged 3D model into 2D sprite sheets, 8
  directions × N frames per animation, verified working on a stand-in model. What remains open is the
  art itself — the sprite sheets an army would ship with — and the battle view consuming them.

## 6. How work is verified

```bash
PROJ="F:/VSC Projects/Project Banner"

# after adding or renaming a class_name script, always:
godotc --headless --path "$PROJ" --import

# full suite (exit 0 = pass)
godotc --headless --path "$PROJ" res://scenes/dev/tests.tscn
# one suite
godotc --headless --path "$PROJ" res://scenes/dev/tests.tscn -- --suite=combat

# two-process restart check (must be two separate processes)
godotc --headless --path "$PROJ" res://scenes/dev/persistence_check.tscn -- --phase=write
godotc --headless --path "$PROJ" res://scenes/dev/persistence_check.tscn -- --phase=verify

# the real rendered game, driven without a mouse
ARGS="--autostart-campaign=2026 --autostart-town=greywatch --autorecruit=5 --autoleave --autoengage --autoattack --autostart-battle --battlespeed=8"
timeout 45 godotc --path "$PROJ" -- $ARGS
```

Three levels, cheapest first. A milestone is not done until level 2 passes:

1. `--import` clean, then the unit suites.
2. The relevant end-to-end suite (`test_e2e_loop.gd`, `persistence_check.tscn`).
3. A real windowed run using the `DevFlags` switches, grepping the log for the actual outcome
   (`arrived at X`, `battle resolved: VICTORY`, `deployed`). **A screenshot is not evidence; the
   log is.** Never report success from reading code.

**The suite wipes campaign saves unless isolation is on** — it now writes to its own namespace, but
do not run suites while the owner is playing without saying so first.

## 7. What the owner wants from you

You are the **director** for the next work item, not the implementer. The operator (another agent)
will do the work and come back to you for audit.

**Pick one next work item and specify it precisely.** Respond with only that specification, in this
shape:

1. **The work item** — one paragraph, plain English, no phase names.
2. **Why it, and not the alternatives** — name the two or three runner-up candidates you rejected
   and the measurement or goal that decided it.
3. **What to build** — the files and functions, at the level of behaviour rather than code.
4. **What proves it** — the specific tests that must exist and fail without the change, plus the
   end-to-end check and the windowed check.
5. **What would make you reject the result** — the failure modes you will look for in the audit.
6. **What must NOT change** — the invariants and locked milestones it must not disturb.

Prefer a work item that is real, verifiable in this repository's own terms, and worth its cost — over
one that is merely large. If the honest answer is that the highest-value next step is *polish or
playability* rather than engineering, say that and justify it.

**Reporting style for the owner:** plain English, verdict first, no phase tables. If a number
belongs in the report, say what it means ("about 4% faster") rather than giving a table alone.
Numbers and detail belong in `docs/`, not in the message to him.
