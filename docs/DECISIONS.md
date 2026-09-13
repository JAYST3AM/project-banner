# Decisions

Significant technical and design choices, with the reasoning. Newest last.
A decision is only worth recording here if it would be expensive to reverse or
non-obvious to a future reader.

---

## D-001: Godot 4.7.2-stable, standard build, GDScript

**Decision.** Use the newest stable Godot 4.x (4.7.2-stable), the standard build
rather than .NET, and GDScript as the only language.

**Why.** The brief asked for the latest stable release, no betas or nightlies.
GDScript needs no toolchain beyond the engine itself, and nothing in the design
needs C# performance: the battle sizes are small and the heavy work is
pathfinding and arithmetic, not hot loops. Choosing .NET would add a runtime
dependency for no current benefit.

**Reversible?** Language choice, yes (GDExtension/C# can be added later). Engine
major version, no - not cheaply.

---

## D-002: Five singletons, and only five

**Decision.** `DebugLogger`, `GameData`, `SaveManager`, `SceneManager`,
`GameManager` are autoloads. Everything else is a plain class.

**Why.** The brief warns against "turning every system into a global singleton".
The test applied here: a system becomes an autoload only if it must outlive a
scene transition. Combat maths, travel, recruitment and name generation fail that
test, so they are ordinary classes the caller instantiates - which also makes them
directly testable.

**Consequence.** Autoload scripts must not declare `class_name` (Godot rejects a
class name colliding with a singleton name). This is the reason `save_manager.gd`
has no `class_name` while `campaign_state.gd` does.

---

## D-003: `GameManager` owns the campaign; `CampaignState` is not a singleton

**Decision.** The campaign lives in `GameManager.campaign` as a plain
`RefCounted` object.

**Why.** If `CampaignState` were itself the singleton, a test could not construct
one without disturbing global state, and "start a new campaign" would mean
clearing a global rather than replacing a value. Splitting them keeps the
lifecycle (`new` / `continue` / `end`) separate from the data.

---

## D-004: Parties store soldier **ids**, not soldier objects

**Decision.** `Party.member_ids: Array[String]`, resolved through
`CampaignState.soldier(id)`.

**Why.** If a party held `Array[Soldier]` alongside a campaign-wide registry, one
person would be serialised twice and a load could produce two live objects for
one soldier - the exact bug class the brief's "critical architecture rule" warns
about. Ids make duplicate ownership structurally impossible.

**Cost.** A lookup indirection in UI code. Worth it.

---

## D-005: The data model was completed in Step 1, ahead of its milestones

**Decision.** `Soldier` (including level, XP, kills, loyalty, traits and personal
history), `Settlement` and `WorldParty` exist from Step 1, even though the
systems that fill them arrive in Steps 2-4.

**Why.** `CampaignState` must be able to hold a player party from the moment a
campaign can be saved, and the save shape should not churn. Growing a data class
is cheap; changing the *serialised shape* of a save after players have saves is
not. The brief's rule - don't implement future functionality unless an interface
or stub is needed - is satisfied: these are records with `to_dict`/`from_dict`,
not behaviour. No recruitment, travel or combat logic was written early.

---

## D-006: Saves are indented JSON, with a version and a migration hook

**Decision.** `user://saves/slot_N.save` holds indented JSON with a
`save_version` field; `SaveManager.MIGRATIONS` walks old documents forward.

**Why.** A hand-readable save is the single highest-value debugging tool during
prototype development - a wrong number can be inspected and, if needed, corrected
without a debugger. The cost (file size) is irrelevant at this scale. Combined
with `from_dict` reading every field via `.get(key, default)`, additive schema
changes need no migration at all.

---

## D-007: Determinism uses a hand-written FNV-1a hash, not `hash()`

**Decision.** `RngService.stable_hash()` implements FNV-1a; campaign seeds derive
stream seeds from it.

**Why.** Godot's built-in `hash()` makes no cross-version stability guarantee. A
campaign seed that changes meaning after an engine upgrade would silently
regenerate a player's world. Fifteen lines of hashing buys permanent stability.

**Also.** Each subsystem gets its own named stream (`rng.stream("bandits")`), so
one system consuming randomness cannot shift another's results.

---

## D-008: Gameplay logic is separated from scenes - `BattleSimulator` is pure data

**Decision.** Combat resolution will live in a `BattleSimulator` operating on
plain objects, with the battle scene as a *view* that draws its state and
forwards player orders into it.

**Why.** Two payoffs: the brief requires gameplay logic separate from UI wherever
practical, and it makes the entire combat loop verifiable in a headless test run
with no rendering, no timing and no input simulation. The Step 5 end-to-end test
depends on this.

---

## D-009: `SceneManager` frees only scenes it created

**Decision.** A scene Godot loaded directly (the boot scene, the test harness) is
never freed by a transition; only `_managed_scene` is.

**Why.** Without this, the first `change_scene()` in a headless test would free
the test runner itself, since the runner *is* `get_tree().current_scene`. The
alternative - a special case for tests - would mean production code carrying test
logic.

---

## D-010: Time conversion lives only in `CampaignClock`

**Decision.** `CampaignClock` is the only place real seconds become game hours.
Movement and AI ask the clock how much time elapsed.

**Why.** The brief explicitly calls this out ("do not bury time conversion
constants inside movement logic"). It also means changing the time scale is a
config edit that instantly affects every system consistently.

---

## D-011: Config reads use dotted paths with explicit defaults, plus a presence test

**Decision.** `config.get_float("xp.per_kill", 20)` rather than generated typed
accessors.

**Why.** Adding a tunable requires no code change, which matters when balancing.
The trade-off is that a typo'd path returns the default instead of erroring - so
`tests/test_core_services.gd` asserts every path the code reads exists in
`game_config.json`. That test is the safety net for this decision; keep it
updated when adding tunables.

---

## D-012: `WorldBuilder` is idempotent, and never overwrites a loaded world

**Decision.** `build_if_needed()` builds settlements and roads only when the
campaign has none. Loading a save never rebuilds.

**Why.** Saved world state (visited flags, later: depleted recruit pools, faction
ownership, destroyed parties) must survive a load. If the builder ran
unconditionally, every load would silently reset the world to its authored
starting state - a bug that looks like "my progress vanished" and is very hard to
attribute. The tests assert both halves: a fresh campaign builds, and a loaded one
does not.

---

## D-013: The world map scene is thin; the HUD builds its own controls

**Decision.** `world_map.tscn` contains only the root, the view, the camera and a
HUD `CanvasLayer`. The HUD, settlement panel and debug panel construct their
widgets in script.

**Why.** Hand-authored `.tscn` files are the highest-friction thing to edit
programmatically: a single wrong property line fails the whole scene, and dynamic
content (a teleport button per settlement, a stat row per value) has to be
generated in code anyway. Keeping the layout in `.tscn` and the content in script
splits one concern across two files for no gain.

**Trade-off.** Less visual editing in the Godot editor. If UI work becomes the
bottleneck, moving the HUD to a real `.tscn` is a contained change - only
`world_hud.gd` reads those node paths.

---

## D-014: Travel is straight-line, and roads are decorative for now

**Decision.** `TravelService` moves the party in a straight line to the selected
settlement. Roads are drawn and stored, but pathfinding does not use them.

**Why.** The milestone's definition of done is "select a destination, travel,
arrive". Pathfinding requires a terrain graph that does not exist yet, and adding
one now would be building future functionality (AI parties, terrain, supply) to
satisfy a milestone that does not need it. `CampaignState.roads` exists so the
graph is already recorded when pathfinding does arrive.

---

## D-015: Development switches live in `DevFlags`, not in scattered `OS.get_cmdline_args()` calls

**Decision.** One class reads the command line and exposes named queries.

**Why.** Automated verification of a *rendered* game needs a way in without a
mouse: the Step 2 windowed check drives `--autostart-campaign` and `--autotravel`
and reads the travel result out of the log. Centralising it means one place to
audit for "does anything ship enabled by accident", and one place to disable it.
Debug UI availability is gated separately by the `debug` config section.

---

## D-016: Names are derived from the seed plus a soldier index, not from a stored generator

**Decision.** `NameGenerator.name_for(index, taken)` derives its randomness from
`seed :: name:<index>:<attempt>` instead of holding a live `RandomNumberGenerator`.

**Why.** A live generator would have to have its state saved to keep names stable
across a load, and generating a name would consume randomness that other systems
also draw from. Deriving from an index means: the same seed always produces the
same soldiers, a name never disturbs another system's stream, and there is no
generator state in the save file at all. It also makes names reproducible in a
test, which is how "unique, deterministic, different across seeds" is asserted.

---

## D-017: Trait modifiers are applied where they belong, not all at once

**Decision.** At recruitment, `SoldierFactory` applies the `morale`, `loyalty` and
`hp_pct` modifiers. The `attack_pct` and `move_speed_pct` modifiers stay in the
data and are applied when a fighting unit is built from a soldier (Step 5).

**Why.** Morale, loyalty and hit points *are* soldier fields, so they are settled
when the person is created and persist. Attack and movement are properties of a
unit *in a battle*, affected by the soldier's equipment and the situation; folding
them into the soldier record now would bake a battle-time concern into permanent
character data. The test suite asserts that the modifiers which are supposed to
apply demonstrably change the starting numbers, so the trait data is never
decoration.

---

## D-018: A test suite that cannot run counts as a failure

**Decision.** The runner refuses to pass a suite that fails to load, fails to
compile, or records zero assertions, and it fails the run if fewer suites reported
than were expected.

**Why.** This is a real bug that happened. GDScript has no exceptions: when
`script.new()` was called on a suite that had failed to compile, the runtime error
aborted `_run_suite` *before* it could record a failure, and the run printed
`RESULT: PASS` with 212 green assertions while a 188-assertion suite had not run at
all. A test harness that can report a silent false green is worse than no harness,
because it converts "I did not check" into "I checked and it is fine". The guards
are: `GDScript.can_instantiate()`, a `checks == 0` post-condition, and a
reported-versus-expected suite count.

---

## D-019: `BattleContext` is the only channel between campaign and battle

**Decision.** A battle scene receives everything through the scene payload as a
`BattleContext`. It never reads `GameManager.campaign`, never resolves a party, and
never consults a unit catalog.

**Why.** The brief requires it, and the reason is worth restating: a battle that
reconstructs its armies from global state can only ever fight the fight the world
happens to be in *right now*. Making the context the only channel means an ambush,
a siege, a tournament or a scripted historical battle is a different context object
and nothing else. It also means a battle is fully describable - and therefore
loggable, replayable and testable - without a campaign.

---

## D-020: Battle snapshots carry identity **and** resolved stats

**Decision.** Each roster entry in the context is a dictionary holding the
`soldier_id` plus the soldier's fully resolved combat stats (including trait
modifiers), rather than a reference to the `Soldier` or a bare id.

**Why.** Two requirements pull in opposite directions: the battle must know exactly
which person it is moving around the field (so it needs identity), and it must not
be able to mutate campaign data or reach into a catalog (so it needs self-contained
stats). A snapshot satisfies both. Trait `attack_pct` and `move_speed_pct` are
applied while building the snapshot, which is the single place D-017 promised they
would be consumed.

---

## D-021: Every overworld party is spawned from data, deterministically

**Decision.** Spawn points are explicit entries in
`data/encounters/bandit_parties.json`; composition is rolled from named RNG streams
derived from the campaign seed; wander targets are derived from the party id and a
persisted wander counter.

**Why.** A campaign seed is only meaningful if the same seed produces the same
world, and that has to include the things trying to kill you. Deriving wander
targets from a counter instead of a live generator means party behaviour needs no
RNG state in the save file, exactly as with soldier names (D-016). The windowed
verification confirmed it: two separate processes with seed 4321 produced identical
soldiers and an identical battle seed.

---

## D-022: Development flags are consumed once where they would otherwise loop

**Decision.** `--autostart-town` is consumed on first use; the other flags are
idempotent and re-evaluate every time.

**Why.** Automated verification returns to the world map several times in one run.
A flag that fires on *every* world-map load turned the intended path
(town -> map -> encounter -> battle) into a loop between the town and the map, which
is exactly the sort of thing that makes a verification run look like it passed when
it never reached the part that mattered.

---

## D-023: The battle scene's debug exit is a real, separate path from Retreat

**Decision.** "Retreat" applies the campaign consequence (push clear, set a
cooldown). "Debug Exit", available only in debug builds, leaves the battlefield
without touching the campaign.

**Why.** A developer inspecting a battlefield repeatedly does not want to move the
player party every time. Keeping them as two paths means the consequence-bearing
one stays honest - it is the path a player takes - while the inspection path stays
free of side effects.

---

## D-024: A battle is described before it is applied

**Decision.** `BattleResolver.build_result()` computes the entire outcome without
mutating anything; `apply()` is a separate call and the only place a battle writes
to the campaign.

**Why.** A fight can be abandoned in several ways - retreat, debug exit, quitting
to the menu, or the process dying. If damage and death were written to soldiers as
they happened, every one of those paths would leave a save file full of
half-resolved state: soldiers at zero hit points but still listed as active,
battles that never concluded. Splitting description from application makes the
failure mode "the battle did not happen" instead of "the battle half-happened".

**Consequence worth knowing.** Because `apply()` reads `BattleResult` alone, a
battle could be applied *later* (after a reload, say) or *not at all*, without
changing any of the code involved.

---

## D-025: Melee reach must exceed the distance the separation pass enforces

**Decision.** Melee `attack_range` values (1.8-2.4) are deliberately larger than
the minimum gap the overlap resolver maintains (1.35), and a test asserts it.

**Why.** This was a real, silent, catastrophic bug. `_resolve_overlaps()` pushed
units apart to 1.35 every step; melee range was 1.0-1.6; so melee units closed,
were pushed back, and *never satisfied the in-range condition*. Melee combat was
completely inert. It was not obvious, because bandit archers (range 9.0) kept
shooting the player's party to death - fights looked like they were working, and
simply ended in a massacre with zero enemy casualties. Twenty-four simulated
openings produced 24 losses and 0 enemy dead, which is what exposed it.

The guard is two assertions: every non-ranged archetype's range must exceed
`separation_radius * SEPARATION_FACTOR`, and a melee-only fight must produce
damage. Either one alone would have caught it.

---

## D-026: Loot is sold immediately, because there is no inventory

**Decision.** Items rolled from `data/items/items.json` are converted to gold the
moment a battle is won, and named on the results screen.

**Why.** The brief asks only for a "loot placeholder", but a placeholder that
accumulates in a dictionary nobody reads is dead data that looks like a feature.
Selling loot for coin is a complete, honest loop today, and when an inventory
arrives the change is "put the item in the bag instead of adding its value".

---

## D-027: Balance is asserted as a range, and reported at both ends

**Decision.** `tests/test_combat.gd` simulates the opening fight across 24
campaign seeds against the weakest bandit band *and* the strongest, prints both
results, and asserts a range rather than a single expected outcome.

**Why.** A vertical slice where the opening fight is always lost hides broken
combat maths (which is exactly how D-025 survived several milestones), and one
where it is always won hides it just as well. Asserting "winnable" and "losable"
makes the test tell you *what the game currently feels like*, not just whether the
code runs. The printed figures - currently 20/24 and 3/24 - are the fastest way to
notice that a data edit has moved the game somewhere unintended.

---

## D-028: The campaign keeps a chronicle of its battles

**Decision.** `apply()` appends a small JSON-safe summary of every battle to
`CampaignState.flags["battle_log"]`, capped at the most recent 40.

**Why.** Two reasons. First, it is the seed of the "the world remembers" feeling
the design principle asks for - the campaign now has a history independent of any
individual soldier. Second, it makes an outcome verifiable after the fact, without
holding on to a live `BattleResult` or peeking at a scene payload, which is what
the end-to-end test asserts against. The cap keeps a long campaign's save bounded.

---

## D-029: Fallen soldiers keep the kills they earned

**Decision.** `apply()` adds a dead soldier's kills to their record before marking
them dead.

**Why.** It is easy to write the survivor path and forget the casualty path - and
this was a real bug found by an end-to-end assertion that the party's total kills
must equal the enemies put down (5 dead enemies, 4 recorded kills). A soldier who
killed someone before they fell did so; losing that quietly rewrites the record of
a fight that actually happened, which is precisely the kind of detail the design
principle says should make the player care.

---

## D-030: Persistence is proven across two processes, not one

**Decision.** The Step 6 check runs as two separate Godot processes
(`--phase=write`, `--phase=verify`) that communicate only through the save file and
a witness file of recorded expectations.

**Why.** A save/load test inside one process proves the serialiser round-trips; it
can accidentally pass while the game cannot actually be reopened (a field that is
held in a live object rather than the save, an autoload that is not reinitialised,
a world that gets rebuilt over loaded state). Two processes make those failure
modes impossible to hide, and the witness file means the verifying process is
genuinely ignorant of what the first one did.

The same reasoning is why the milestone's wording is "survives a complete
application restart": it is a statement about the game, not about the serialiser.

---

## D-031: A save from a newer build is refused, not read

**Decision.** `load_campaign()` returns null for a document whose `save_version`
exceeds this build's, logs why, and the main menu disables Continue and explains.

**Why.** The alternative - reading it anyway and taking whatever fields happen to
match - silently discards everything it does not understand. That is the worst
outcome for a player: their campaign appears to load and has quietly lost
soldiers. Refusing is loud, safe, and recoverable (the save is untouched).

---

## D-032: Migration entries are runtime Callables, with a real v0 step

**Decision.** `SaveManager.migrations` is populated in `_ready()` with
`Callable(self, "...")` rather than being a `const` dictionary, and it ships with a
working v0 -> v1 step.

**Why.** A *const* table would have meant shipping an empty, untested mechanism with
a comment promising it works. A real, exercised step is what proves the migration
path actually runs: "an unversioned save migrates" is an assertion, not an
intention. Beyond that, additive schema changes never need a migration at all,
because `from_dict` reads every field with a default - so migrations exist only for
the removals and renames that genuinely need them.
