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
