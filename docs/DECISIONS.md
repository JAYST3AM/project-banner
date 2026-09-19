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

---

## D-033: A withdrawal is its own battle outcome, with its own progression rules

**Decision.** `BattleResult.withdrawal` is an explicit field, set from the winner
once in `build_result()` and never inferred downstream. A withdrawal:

- records `battles_fought` for everyone who took the field;
- does **not** increment `battles_survived` for anyone;
- pays experience **only** for kills actually made - no participation bonus, no
  survived-battle bonus, no victory bonus;
- pays no gold and takes no loot;
- leaves the enemy party on the map unless it was genuinely destroyed;
- pushes the player clear and sets an encounter cooldown, like any other
  non-victory.

**Why.** The behaviour it replaces was a farming loop. Entering a battlefield and
pressing Retreat immediately still ran the ordinary survivor path, so a soldier
could collect participation plus survived-battle experience for a fight that never
happened - costing nothing, repeatable forever at two clicks a cycle. Progression
that can be had without risk is not progression.

Kills are the deliberate exception. A soldier who cut someone down before the line
broke really did that, and erasing it would rewrite the record of something that
happened - the same reasoning as D-029. `battles_fought` is likewise honest:
taking the field is a fact, whatever came of it.

Carrying the outcome as a flag rather than re-deriving it from the winner string
means there is exactly one place where "we broke off" is decided, so the rules
cannot drift apart from the label.

---

## D-034: Roster membership and active force are separate numbers

**Decision.** `Party.size()` is historical membership - everyone who ever belonged,
the dead included. `CampaignState.active_member_count()` is the force. Travel pace,
party capacity, encounter strength, enemy markers and every "how strong is this"
display use the **force**. The roster screen lists the **membership** and states
both ("8 / 24 active, 4 lost").

**Why.** Keeping the dead is a design commitment: casualties must stay inspectable,
because the whole premise is that soldiers are people rather than counters. But it
means two different quantities describe one party, and the wrong one fails quietly.
The original code used the roster count for travel pace, so a company that had lost
three quarters of its strength still marched at the speed of a full one - casualties
made you no faster. The HUD made the same mistake in the opposite direction,
showing `24 / 24` while the recruitment screen, which correctly counted the living,
still offered replacements.

Neither number is wrong on its own; using them interchangeably is. Hence two named
accessors rather than one, and a doc comment on `Party.size()` saying which it is.

---

## D-035: A battle stops dead when it times out

**Decision.** `BattleSimulator.step()` returns immediately after `_finish("")` on
timeout. No unit updates, no attacks, no overlap resolution, no victory check.

**Why.** The timeout check sat above the unit loop, so the step that ended the battle
carried straight on and processed a full delta of combat against a battle that had
already been declared over. Units could move, strike, take damage and die after the
end. The fix is one `return`, and the regression test asserts something stronger
than "it finished": that no hit point and no position changed on the finishing step,
that no hit or death event was emitted, and that later `step()` calls are inert.

---

## D-036: A suite must reach its completion marker to pass

**Decision.** `TestCase.completed` is set only by `_complete()`, which every suite
calls as the last statement of `run()`. A suite that recorded assertions but never
reached the marker is reported **BROKEN**, not passed.

**Why.** Verified against Godot 4.7.2 rather than assumed, with a throwaway probe: a
runtime error aborts the function, control **does** return to the awaiting caller as
if the function had ended normally, and the suite comes back reporting
`3 assertions, 0 failures`. A runner checking only the failure count calls that a
pass. The completion marker is the only signal that distinguishes "finished
cleanly" from "died in the middle", and it survives the abort because it is a
statement the aborted function never reaches.

A suite that legitimately asserts nothing is also BROKEN: it cannot demonstrate
anything, so passing it is a false green of a different kind.

---

## D-037: A `--suite=` filter that matches nothing is a failure

**Decision.** `_run_all()` treats an empty selection as a failure, prints the filter
and the list of available suites, and exits non-zero.

**Why.** With no suites selected every count is zero, and zero failures reads as a
clean run. A typo in a milestone command would silently disable the gate that is
supposed to be protecting the milestone - the failure mode is a green build with no
tests behind it. The selection logic was also split into a pure
`select_suites(filter)` so the self-tests can check the matching rules directly
instead of faking command-line arguments.

---

## D-038: `peek_metadata()` understands every shape the game claims to load

**Decision.** Metadata extraction tolerates both save shapes (v0's bare-array
`player_party` and v1's object), reads nested dictionaries defensively, and
**does not** run the migration chain or write to the file.

**Why.** Migration made the legacy shape loadable, but the menu peeks *before* any
of that runs - so a save the game could happily migrate could still error the moment
the player opened the menu, on the exact shape the v0 migration step exists to
handle. A save the game claims is loadable must at least be *describable*.

Not migrating during a peek is deliberate: reading a menu should never rewrite the
player's save file, and the peek has to work on documents the game will go on to
refuse (a save from a newer build, per D-031). Tolerance in the reader, not mutation
of the artefact.

The same pass added `party_active` and `party_lost` (D-034), because the menu was
listing the roster count as though it were the force.

---

## D-039: Tests wait for transitions; they never cause them

**Decision.** `SceneManager.await_scene(key)` waits for a transition that has
already been requested and returns the instantiated scene. The Step 5 end-to-end
test uses it in place of a second `change_scene_and_wait`.

**Why.** The battle scene already transitions itself to `battle_results` with the
real `BattleResult`. The test then called `change_scene_and_wait("battle_results")`,
which queued a **second** transition carrying no payload - replacing the first. The
screen fell back to "No battle result was passed to this screen", and the test
cheerfully confirmed that the scene existed. It had verified nothing about the
payload while looking thorough.

Waiting is not the same as causing, and the distinction needed an API. The test now
also reads what the screen is actually displaying (`displayed_result()`,
`displayed_text()`) and checks it against the campaign's own chronicle, so it proves
the real fight reached the real screen.

---

## D-040: The battle chronicle is read by id, not as "the latest"

**Decision.** `_log_entry_for(state, battle_id)` searches the chronicle. The
persistence check no longer calls `last_battle_summary()` to find the battle it
cares about.

**Why.** Once the restart check fought a second battle (the withdrawal), "the latest
entry" was a different fight, and five assertions compared the *first* battle's facts
against the *second* battle's log entry. The failures were loud rather than silent,
but the underlying assumption - that the entry you want is the last one - is simply
false for any campaign that has fought more than once.

---

## D-041: Battle consequences are symmetric - enemy soldiers persist too

**Decision.** `BattleResult` carries `enemy_survivors` alongside `enemy_dead`, and
`BattleResolver.apply()` writes enemy post-battle state back to the campaign:

- **survivors**: `hp` (their real remaining hit points), `kills`, `battles_fought`,
  and `battles_survived` on the same rule as the player's soldiers - taking the field
  counts, breaking off does not;
- **the fallen**: `hp = 0`, dead, `battles_fought`, and the kills they made before
  falling, which `_fallen_entry` had been recording and `apply()` had been discarding.

Enemy soldiers get **no** experience, levels, loyalty, morale progression or equipment
damage. They have no XP curve and no progression in Steps 0-6, and inventing one here
would be a new system rather than a record of what happened. `damage_dealt` stays in
the result entry (where the results screen already reads it) and is deliberately not
added to `Soldier`, because item 5 of the audit asks only for fields the model already
supports.

**Why.** A party that keeps its soldiers as persistent people, but only persists the
ones the player owns, is not persistent - it is one-sided. The concrete failure: an
enemy damaged to 23 hit points and left standing (player withdrew, lost, or the clock
ran out) returned to the campaign at full health and was a completely fresh band next
time. Every withdrawal was a free reset for the enemy, so a hostile band could never
actually be worn down, and the strategic option of "bloody them, pull out, come back
stronger" did not exist.

The dead half was the same bug as D-029, one layer further out. `_fallen_entry` duly
recorded an enemy's kills, and `apply()` then threw them away - so a bandit who cut
down two of the player's soldiers before dying was remembered as having killed nobody,
in exactly the fight where those kills mattered most.

**A consequence worth stating:** the resolve-then-apply split (D-024) is what makes
this a small change. The battle already knew everything; only the write-back was
missing. `build_result()` still mutates nothing, and the regression test checks that
attacking it directly.

---

## D-042: CI is an independent gate, pinned to the engine version

**Decision.** GitHub Actions runs the full headless suite and the genuine two-process
restart check on every push to `main` and every pull request against it. The workflow
installs Godot **4.7.2-stable** by explicit release URL, asserts the installed engine
reports that version, and fails the job if any verified step fails.

**Why.** Local tests prove the suites pass on one machine. They cannot catch a test
that depends on something local - an import cache, a stale `.godot/`, a save file left
behind by an earlier run, a difference in working directory. A clean checkout on a
clean runner is a different question, and it is the question that matters before the
foundation is declared locked.

Pinning is the other half. "Latest Godot" would make CI report on the engine rather
than on the project, and a red run would not tell anyone which of the two had changed.
Installing the pinned release is also not the same as running it, so the workflow
asserts `godot --version` rather than trusting the download.

Two deliberate details:

- **No `continue-on-error` on any verification step**, and no command piped in a way
  that could swallow the engine's exit code. `set -o pipefail` plus `tee` keeps the
  failure, and each phase additionally greps its own log for the runner's explicit
  `PASS` line - so a run that somehow exited 0 without reporting PASS is still red.
- **CI does not fail on the runner self-test's deliberate runtime error.** That
  fixture provokes a real engine error to prove an aborted suite is caught, and the
  engine exits 0 because the suite handles it. Adding a "fail on SCRIPT ERROR" step
  would break the very mechanism that keeps the runner honest; the workflow says so in
  a comment, so nobody removes the fixture thinking they are cleaning up output.

---

## D-043: Terrain is simulation data with a view, not a rendered thing with a model

**Decision.** `BattlefieldTerrain` is a `RefCounted` grid of type, elevation and
resolved movement multiplier. It is generated from a seed, queried by position, and
knows nothing about how it is drawn. The renderer reads it; it never reads the renderer.

**Why.** The alternative - terrain implied by whatever tiles happened to be on screen -
makes the ground a presentation detail that gameplay then has to interpret, and the
first time an artist moves a tile the balance changes. It also makes the battlefield
untestable headlessly, and every milestone in this project is gated on headless tests.

The split is enforced by types rather than by convention: `BattlefieldTerrain extends
RefCounted`, so it *cannot* be a node, and a test asserts exactly that. A rule enforced
by the compiler is one nobody has to remember.

## D-044: A cell's terrain comes from hashing where it is, not from a generator's state

**Decision.** `BattlefieldTerrain.generate()` derives both noise fields from
`RngService.stable_hash` over each lattice coordinate. It does not use a
`RandomNumberGenerator`, and it does not depend on the order cells are visited in.

**Why.** Determinism from a seeded generator is only as good as the discipline of
everyone who touches the loop. A hash of the coordinate is deterministic by
construction: reordering the loop, generating one cell, or generating the field twice
all give the same answer, and there is no state to accidentally advance. It also means
generating a battlefield cannot disturb any other random stream in the process - a test
proves a seeded `randi()` returns the same value whether or not terrain was generated in
between, because a shared generator would have made every battle after the first
subtly different.

`terrain.generation_version` is mixed into the hash. Changing how terrain is generated
therefore changes the ground on purpose, rather than silently changing what an existing
seed means.

## D-045: Terrain affects movement only, for now

**Decision.** Step 7 terrain changes how fast soldiers move across it and nothing else.
No attack or defence modifier, in either the data or the code.

**Why.** The brief said terrain must affect something real and must not be overbuilt,
and it explicitly allowed a small elevation combat effect "if appropriate". It is not
appropriate yet: a defence modifier would change the outcome of every seeded battle in
the balance measurements, which means re-deriving a set of numbers that currently mean
something, in exchange for a bonus nobody can feel yet. Movement is a real consequence -
crossing woods takes visibly longer, and a test measures the ratio against the type
table's own numbers rather than against a hardcoded expectation.

The terrain type table is where a defence field would go. Adding it later is a data
change plus one read in `_attack()`, and it should be done when there is a mechanic
that makes it interesting.

## D-046: A formation is a geometry, not an enum with bonuses

**Decision.** `BattleFormation` holds real state: anchor, facing, desired facing,
frontage, depth, spacing, file and rank counts, per-soldier slot positions, order, and
a measured cohesion. Formation types are data - `data/formations/formation_types.json` -
and supply geometry and movement parameters, not modifiers.

**Why.** The brief's first pillar is that formations must matter through geometry,
facing, spacing, cohesion and terrain rather than through `shield wall = +15% defence`.
That is only achievable if the formation actually knows its shape. A formation that
only knows "I am a shield wall" cannot have its value depend on how tightly it is packed
or whether its flank is turned, because it has no packing and no flank.

Concretely, a type in the table supplies `max_files` - how wide the shape is willing to
spread - plus a spacing multiplier, a turn rate and a move factor. Everything else is
derived. That is why line, column and loose differ in ways a test can measure (frontage,
depth, spacing) without any of them being special-cased in code, and why adding a wedge
or a square later is a data entry plus, at most, a generator for a non-rectangular slot
pattern.

## D-047: Slots are generated in the formation's own frame, then transformed

**Decision.** Slot positions are computed as `anchor + right * lateral + forward * depth`,
where `right` and `forward` come from the formation's facing angle.

**Why.** The obvious implementation - place a line along X, a column along Y - works for
exactly the two directions deployment happens to use, and then every facing-sensitive
mechanic added later has to unpick it. Generating in local space makes arbitrary facing
a rotation rather than a special case, and although Step 7 implements no directional
mechanics, the shield wall, phalanx frontage, flanking and rear-attack systems that come
later all need a formation to be able to say which of its edges is its front.

A test drives seven facings including 37, 143.5 and -61 degrees and checks that
neighbours are one spacing apart along the formation's own width at every one of them.

## D-048: Assignment is by index, and a casualty leaves a gap in the line

**Decision.** `unit_ids[i]` owns `slots[i]`. A formation change leaves every soldier in
the same place in the order, so it walks to a new position rather than being reshuffled.
A fallen soldier is **not** removed from `unit_ids`: its slot stays reserved and the
formation keeps its frontage with a hole in it.

**Why, for the first part:** the brief asks for stable, deterministic assignment that
preserves existing assignments and reassigns only when necessary. Index stability gets
that without an assignment solver, and it has a property worth keeping - a soldier
changing formation type keeps its place in the queue, so the reorganisation reads as the
same body changing shape rather than as strangers finding new seats.

**Why, for the second part:** the obvious alternative - compact the roster on death -
re-dresses the entire formation every time anyone falls, which means a large battle has
its soldiers permanently shuffling forward, and it is O(size of formation) per casualty.
Keeping the slot costs nothing and is more honest about what a formation is: a gap in a
line is a real thing, it is what makes a formation permeable, and the shield wall and
phalanx work that comes later will specifically want to know about it. Removing a
soldier is still possible via `remove_unit()` for transfers; it is death specifically
that leaves the gap.

## D-049: A formed soldier's place is its whole job

**Decision.** A formed soldier whose enemy is in reach fights. Otherwise it walks to the
slot the formation gave it. It does not choose its own ground, and it does not leave its
place to chase a target.

**Why.** This is the architectural change the milestone exists to make. Before Step 7,
every soldier independently picked the nearest enemy and walked at it, which meant the
"army" was a hundred separate decisions that happened to start in a block. Now the
formation decides where the body is and the soldiers dress to it, which is both the only
way a line stays a line and the only way a large battle stays affordable - most soldiers
are doing arithmetic, not deciding anything.

It also puts the decision where the brief says it belongs: above the soldier. The future
performance model is one order per formation and then cheap local execution, not twenty
thousand tactical planners.

## D-050: Engagement is a stance, and a stalled battle is restarted by pressing forward

**Decision.** A formation's order is `engage`, `hold` or `move`. `engage` is the default.
A body that has stopped, has been told to engage, and whose side currently has nobody in
reach of anybody, lets its soldiers leave their places and close the distance.

**Why.** Without a default stance, a battle where the player gives no orders never
resolves - and "the lines fight when they meet" is behaviour the game already had and
must keep.

But the default stance alone was not enough, and the reason is worth recording because
it was found by running the game rather than by thinking about it. A battle resolved to
nine players against one enemy and then stopped for four simulated minutes: the survivor
was standing in the gap left by a fallen man, 2.6 units from the next soldier along,
which is further than a sword reaches. Both bodies were engaged and both had stopped, so
neither would close and neither could reach. A battle that cannot end is worse than a
battle that ends badly.

The fix is narrow on purpose. Pressing forward requires all three of: the body is
engaged, the body has stopped, and *nobody on that side is in contact*. The third
condition is what makes it safe - if the line is fighting, dressing wins and no soldier
leaves it, so a battle cannot dissolve into a crowd. The state costs one boolean,
maintained inside the per-soldier reach test that already had to be made, so the check
is a lookup rather than a search.

Related and deliberate: an engaged body's arrival tolerance is `0.05` units rather than
the `0.6` used for waypoints. A body closing on an enemy is not making for a map pin, and
stopping six tenths of a unit short of one is indistinguishable from stopping.

## D-051: Enemy thinking lives outside the simulator

**Decision.** `BattleAI` is not called by `BattleSimulator`. Whoever owns the battle loop
calls `ai.update(simulator, delta)` before `simulator.step(delta)` - the battle scene
does, the benchmark does, the tests do.

**Why.** A simulator that thinks on its own is a simulator whose tests cannot isolate
what they are testing. Keeping the commander outside means most of the suite steps a
battle with no AI attached and gets exactly the mechanics it asked for, while the scene
and the benchmark attach one and get a battle that progresses.

It also keeps the boundary honest for the future. What `BattleAI` does today is small -
face the enemy, tell the body to engage - and that is the point: closing the distance is
not decided there, because the battlefield is the only thing that knows where anyone is
standing. The AI says *what the body is for*; the battlefield works out what that means
this step. Flanking, refusing a flank and withdrawing are decisions, and they belong in
the same place this does.

## D-052: Formations are battle state and never enter a campaign save

**Decision.** No formation data is written to a save file. A battle reconstructs its
formations from the `BattleContext` when it starts. The save format is unchanged and
`save_version` stays at 1.

**Why.** The brief says not to add formation state to campaign saves without a strong
reason, and there is no strong reason: a formation is a thing an army is doing during
one afternoon's fight, not a fact about who a soldier is. Persisting it would mean a
save written mid-battle has to describe a half-executed manoeuvre, and every future
change to formation geometry would need a migration for data that is discarded the
moment the battle ends anyway.

What survives a battle is still exactly what survived before Step 7: `BattleResult`
describing what happened to individual soldiers, applied by `BattleResolver.apply()`.
The existing saves load, the existing restart check passes, and the persistence suite -
including the legacy-save path through the real main menu - is untouched.

## D-053: The quadratic loops are measured and documented, not rewritten

**Decision.** `_choose_target()` and `_resolve_overlaps()` compare every soldier with
every other soldier. Step 7 measures what that costs at 100 to 5,000 soldiers, records
the result in the report, and does not restructure the simulation.

**Why.** The brief is explicit: do not perform a large architecture rewrite merely
because 5,000 is slow, and do not claim a future capacity based on design alone. Both
temptations are real here, and the honest middle path is a benchmark that produces
numbers, an attribution that shows the new systems are not the cause, and a written
record of what would have to change.

The specific thing that would make this a mistake to fix now: optimizing before there is
a target to optimize against produces an abstraction shaped by guesswork. A spatial grid
sized for Step 7's two-army field would very likely be the wrong shape for a battlefield
with cavalry on the wings and reserves in the rear, which is what the large-battle
milestone will actually be optimizing for.

What Step 7 does owe the future is not making it worse: every loop it adds is linear in
soldiers, and the per-soldier cost of standing in a formation is a reference and an array
read. A test asserts the type of that access, so the property is checked rather than
claimed.

---

## D-054: Membership belongs to the formation, and invalidates geometry on the way through

**Decision.** `unit_ids` is changed only through `BattleFormation.set_units()`,
`remove_units()`, `add_unit()` and `remove_unit()`. Every one of them marks the slot
geometry dirty, flags the body as reforming, and **rebuilds the slots before returning**.
No caller edits the list, and no caller has to remember to invalidate anything.

**Why.** Step 7 had `BattleSimulator.assign_formation()` remove departing soldiers from a
donor formation's `unit_ids` directly, then call `ensure_slots()` - which rebuilds only
when something has already marked the geometry dirty, and nothing had. The donor went on
reporting the files, ranks, frontage, depth and slot positions of the body it had been
before the detachment, and nothing was ever going to correct it. A player could detach
four men from a dressed twelve-man line and watch the line keep the frontage of a body it
no longer was, indefinitely.

Two properties make this a design decision rather than a bug fix. The first is that the
rule is enforced rather than remembered: the failure mode is "somebody forgot to call
`_invalidate()`", and the fix is to make forgetting impossible, not to try harder. The
second is that the rebuild is eager. A merely-dirty formation is still wrong until
somebody asks, and the whole point is that nobody reliably asks.

The per-tick path deliberately keeps the opposite trade: `advance()` marks the slots
dirty and lets the step's own `ensure_slots()` do the work, because that runs every tick
for every body. A shape change or a transfer happens when somebody gives an order.

`set_type()` had the same defect one layer over - marking dirty and leaving `file_count`,
`rank_count`, `frontage()` and `depth()` describing the shape the body was walking out of
- and is fixed the same way. That one was found by reading a windowed run's own log,
which reported a seven-man line as "6 files by 2 ranks": loose order's geometry, printed
under the line order that had just replaced it.

## D-055: The AI asks whether a body is alive, not whether it is empty

**Decision.** `BattleAI` skips any candidate formation for which `has_living_units()` is
false - the same method the simulator uses to choose its own targets. `is_empty()` is not
used to mean "combat-capable".

**Why.** They are different questions that look like one. "Is this formation empty" asks
whether it was ever given anybody; a wiped-out body is not empty, because casualties are
kept on its roll on purpose so that a gap in a line stays a gap (D-048). So an AI picking
the nearest enemy body would pick the corpse of the body it had just destroyed - it was
still nearer than the survivors - and order its soldiers to face men who were already
dead.

The fix is small; the reason it is worth a decision is the second half. There is now one
definition of an active body, asked in the same way from both places, rather than two
that happen to agree until somebody changes one.

## D-056: Contact is a property of a formation, not of a side

**Decision.** `BattleFormation.in_contact` records whether any soldier of that body
currently has an enemy within reach. It replaces the side-wide flag Step 7 used. The
stalemate-breaking rule from D-050 - a stopped, engaged body whose side has nobody in
contact lets its soldiers press forward - now reads the body's own state.

**Why.** With one flag per side, *any* player soldier being in reach of *any* enemy
marked the entire player side as engaged. Step 7 only had one body a side, so it never
showed. The moment an army can be split - and detaching a group is a player command in
the HUD right now - a wing that has not reached anybody is told it is in contact, its
soldiers hold their dressing instead of closing, and it stands where it is while the
centre fights. That is the stalled battle from D-050 again, one formation over: the rule
that fixes a stalled fight was itself being suppressed by an unrelated fight elsewhere.

The cost is unchanged. The flag is set inside the per-soldier reach test that already had
to be made, so it is a boolean write rather than a second battlefield-wide pass - which
matters, because the loops that are already quadratic are documented and waiting (D-053).

Cleared between the formation orders and the soldier updates in each step, which is the
only place it can be: the orders read it, the soldiers write it, and clearing it on
either side of that boundary loses one of the two.

## D-057: `slope_between()` returns zero when either point is off the field

**Decision.** The off-field check happens before the height lookup, and covers either
endpoint. This is what the method always documented and did not always do.

**Why.** Off-field ground reads as zero height, which is the forgiving answer for a
single query (D-043). Reading two heights independently therefore made two off-field
points happen to return zero - so the existing test passed - while one point inside and
one outside returned a real-looking number that meant nothing. The edge of the field
appeared to fall away into nothing, and a caller could not tell that from a hill.

A slope to somewhere that does not exist is not a small number. It is not a slope, and
zero is the honest answer - the same answer the method already promised.

## D-058: Debug bounds are derived from the slots, not from the body's own axes

**Decision.** `BattleFormation.bounds()` returns the axis-aligned box containing the
actual slot positions. It is not an oriented rectangle, and it is not computed from
frontage and depth.

**Why.** Frontage and depth are the body's size *along its own axes*. A formation at
forty-five degrees has slots running diagonally, so a box built from its width and depth
around the anchor drew a thin horizontal strip containing almost none of the men - the
slots rotated with the formation and the rectangle did not. A debug overlay whose whole
job is to make behaviour observable cannot lie about where the soldiers are, and this one
lied most at exactly the facings the later directional mechanics will care about.

Axis-aligned rather than oriented on purpose: an oriented rectangle would be a second
geometry system to keep correct, and the requirement is only that the box truthfully
contains the body. The cost is a linear pass over the slots, on a method that is called
by the debug overlay and by tests rather than by the simulation.


## D-059: The proximity index answers in cells and promises nothing about order

**Decision.** `BattleSpatialGrid` exposes `collect_within(position, radius, side, out)`,
which returns every indexed unit whose cell the search box touches, in ascending cell
order and then in the order the units were handed to `rebuild()`. It does not sort, and
it does not promise to be the nearest. Callers measure.

**Why.** A cell query that returned candidates "nearest first" would have to sort, and a
sort is exactly the per-candidate cost the grid exists to avoid. What callers actually
need differs anyway: one wants the nearest, one wants everyone within a separation
distance, one will later want everyone in an arc. Returning a superset in a defined
order lets each of them do its own arithmetic once, on candidates it already has to
measure.

The order is part of the contract rather than an accident, because two callers depend on
it: the overlap pass resolves pairs in the order it meets them, and the equivalence
tests pin that order against the loop it replaced. A data structure whose iteration order
is unspecified cannot make that promise, so the order is specified. See D-062 and D-066.

## D-060: The cell size is one configurable number, and density is reported rather than assumed

**Decision.** The cell size comes from `battle.spatial_cell_size`, currently 4.0 world
units; the radius at which a target search starts comes from
`battle.target_search_radius` (8.0), and the ladder by which it widens from
`battle.target_search_escalation` (4.0).

**Why.** Four units is chosen against the numbers that already exist rather than picked
for looking round: melee reach is 1.8, the separation minimum is 1.35, and formation
spacing is 2.6 to 4.4. A cell that comfortably exceeds every local radius means a query
touches one or two cells in the common case and the per-query cell overhead stays near
its floor. Anything much smaller multiplies the cell count walked per query; anything
much larger turns a cell into a bucket of half the army.

The number lives in config rather than in the class because it is tuning, and the
benchmark reports the busiest single cell at every size so that "is this cell size still
right?" is answered by a measurement rather than by re-reading this paragraph. On a fixed
battlefield, density rises with the army, so that column is expected to grow - and at
some size it will say the field itself is too small, which is a different problem with a
different answer.

## D-061: A target search widens from the soldier outward and stops at the first radius that finds anyone

**Decision.** `BattleSimulator._choose_target()` queries the grid at
`battle.target_search_radius`, and if that returns no enemy within the radius, multiplies
the radius by `battle.target_search_escalation` and tries again, up to a ceiling that
defaults to the battlefield's diagonal. The nearest enemy within the first radius that
contains an enemy at all is returned; ties go to the lower unit id.

**Why.** This is exactly equivalent to the battlefield-wide scan it replaced, and the
equivalence is a property rather than a hope: if the search stops at the first radius
containing any enemy, then the nearest enemy inside that radius *is* the nearest enemy,
because anything nearer would have been inside the smaller radius that found nobody. A
test proves the two agree soldier for soldier, over generated layouts and over eighty
ticks of a moving battle.

Ties are broken explicitly on the lower id rather than left to whichever candidate the
grid handed back first. A bucket is a linked list; letting its order decide who a soldier
attacks would make a battle depend on how the index was built, which is precisely the
nondeterminism a spatial index must not introduce.

The starting radius is deliberately not tied to melee reach. Ranged units, long spears
and cavalry threat detection all want to search further than they can hit, and widening
a ladder is a config change. Step 7.2 adds none of those systems; it just declines to
make them impossible.

## D-062: Overlap pairs are resolved once, by the lower id, in the order the pairwise loop used

**Decision.** `_resolve_overlaps()` asks the grid for the units near each soldier and
processes a pair only when `other.id > unit.id`. The outer loop walks the unit list in
its own order and the inner one walks a bucket, and buckets are appended to rather than
prepended to, so the pairs are considered in the same relative order the exhaustive
`for i: for j in range(i+1, n)` loop considered them.

**Why.** The pair rule exists because without it an overlapping pair is pushed twice -
once from each side - and the second push is a second independent event rather than the
same one. That doubles the work and makes the outcome depend on which soldier was
considered first. The rule is written in ids rather than array positions so it survives
any future reordering of the unit list.

The order is preserved because it is load-bearing for behaviour, not for tidiness.
Positional relaxation is sequential: each push changes the positions the next pair is
measured against. A version that visited the same pairs in a different order would be
equally defensible and would produce different battles, which would mean an optimisation
had quietly changed the game. Since a pair that is out of range does nothing, skipping
the far ones is a no-op - so preserving the order makes the spatial pass produce *the
same positions* the exhaustive loop produced, and a test checks that directly against the
exhaustive loop, on eight arrangements including a cell-boundary pair and two soldiers in
exactly the same place.

## D-063: Liveness is checked when a query is answered, not only when the index is built

**Decision.** `BattleSpatialGrid.collect_within()` skips units that are no longer alive,
and `rebuild()` skips them too.

**Why.** The index is a snapshot taken at the start of a tick, and soldiers die *during*
that tick's soldier loop. Indexing only the living is not the same as answering only
about the living: a soldier processed late in the loop would otherwise be handed a
comrade who fell earlier in the same tick and could select, face, chase or shove a
corpse.

This was a real defect, found by a probe comparing the local search against the
battlefield-wide scan on a live battle rather than by reasoning about it. The scan
re-checked `is_alive()` on every candidate and the grid did not, so the grid returned a
different nearest enemy in a real fight, which changed a battle's outcome. It is the
clearest argument in this milestone for the equivalence tests existing at all: the bug
was invisible to every test that only asked whether the battle finished.

Dead soldiers remain on their formation's roll so that a gap in a line stays a gap
(D-048). They are simply not answerable.

## D-064: Profiling is development-only, and the unmeasured path is unchanged

**Decision.** `BattleSimulator` carries phase accumulators behind `profile_enabled`,
false by default. Every entry point returns immediately behind that boolean, and the one
place that would otherwise have cost a function call per soldier without profiling has
two copies of its loop instead of one guarded one.

**Why.** The brief for this milestone asks to be able to say where the time goes, and
also asks that instrumentation not be paid for in production. Those are in tension only
if the guard is inside the hot loop; a duplicated loop costs a line of source and nothing
at runtime. The measured phase set is deliberately coarse - grid rebuild, formation
update, per-soldier update, the share of that spent choosing targets, overlap resolution -
because the question worth answering is which phase to attack next, not which statement.

The profiled figure is not the figure in the benchmark's main table. Two clock reads per
soldier are affordable but not free, and a benchmark that reported a profiled number as
an unprofiled one would be lying by a few per cent. Both are printed, labelled, and the
comparison table uses the unprofiled one.

## D-065: The query radius filters the candidate set; it is a promise, not a hint

**Decision.** `_nearest_enemy_within()` discards candidates further away than the radius
it was asked about, even though the grid already narrowed the field.

**Why.** The grid returns a *box*, not a circle, and the box is deliberately larger than
the circle so that a soldier who has walked since the snapshot cannot be missed. That is
harmless for finding the nearest - a superset cannot hide one - and fatal for the
escalation, which stops at the first radius that returns anything. Without the filter, a
candidate half a cell beyond the radius ended the search early and the answer was a
soldier who was not the nearest after all: not a near miss but a different decision, in
the first radius rather than the last.

This was the second real defect of the milestone and it too was found by the probe, not
by reasoning: the escalation's correctness argument is only true if the radius means what
it says. It is now stated as a filter rather than a description.

## D-066: A query walks occupied cells when that is fewer cells than the box contains

**Decision.** `rebuild()` records every cell holding at least one unit, kept sorted by
cell index. `collect_within()` walks that list instead of the box when the box spans more
cells than there are occupied ones.

**Why.** A uniform grid is cheap because most cells are empty and a local query touches
few of them. The widest rung of a target search inverts that: on a sparse battlefield it
covers most of the field, and stepping through every cell in the box means reading
hundreds of empty bucket heads to find a handful of soldiers. Walking the occupied cells
costs one pass over the soldiers who exist. Both visit the same cells in the same order,
so this changes the cost and nothing else - which is why the list is kept sorted, since
an optimisation that reordered the answer would not be an optimisation (D-059, D-062).

The measurement that motivated it: on a fixed field, a hundred soldiers were searched by
a box covering three hundred and seventy-five cells of which two held anybody. The
milestone is about removing work proportional to the battlefield rather than to the army,
and this was a place where the new code had reintroduced exactly that.

## D-067: A target search is bounded, and beyond the bound a soldier is pointed at the fighting

**Decision.** A soldier searches for its own nearest enemy out to
`battle.target_search_max_radius` (32 world units), escalating from
`battle.target_search_radius` (8). If there is no enemy inside that bound, it is given its
body's *focus* - the nearest living enemy to its formation's anchor, recomputed once per
tick - or, if it is not formed, the nearest living enemy to its side's centre of mass,
computed once per tick per side on demand.

**Why.** A local search cannot answer "who is nearest to me" for a soldier standing half
a battlefield away; answering it requires examining the whole enemy army, which is the
quadratic scan this milestone exists to remove. Measured with the profile clock at two
thousand five hundred soldiers, the unbounded version spent **3,490 ms of a 3,526 ms
soldier loop** on target selection: ninety-nine per cent of the phase, and a per-tick
cost worse than Step 7's. Bounding the search took the same battle from 3,684 ms per tick
to 203 ms.

The trade is real and is stated rather than buried: *within* the bound the answer is
unchanged and provably identical to the exhaustive scan (D-061), and that is where every
soldier who is actually fighting lives. Beyond it, a soldier marching towards a distant
enemy is aimed by its body rather than by its own private measurement, so the specific
enemy it faces at long range may differ from the one the old scan would have picked. Its
*conduct* does not: a formed soldier dressing to its slot does not steer by its target at
all, so the visible difference is the direction it faces while marching. The brief for
this milestone asked for exactly this pattern - "a formation supplies an opposing
formation; soldiers search locally around their formation's contact region" - and asked
that a soldier not be left unable to find the battle.

That last part is what makes the fallback non-optional rather than an optimisation. A
bounded search with no answer beyond the bound is an army that stands still, so the test
that matters is the one asserting every living soldier has something to face at every
tick of a battle that starts with the armies most of a field apart.

The side fallback exists for battles that have no formations at all - the legacy
deployment path - and is computed on demand rather than every tick, because a battle with
formations never asks for it.

## D-068: The grid records which sides are present in a cell, so a query can skip a bucket without walking it

**Decision.** `BattleSpatialGrid` keeps one byte per cell recording whether the player,
the enemy, or both are present. A query that asks for one side reads that byte and skips
the cell when the side it wants is not in it.

**Why.** This is the second half of D-067's cost. After bounding the search, the largest
remaining term was a target query covering a box that contained the soldier's own army
and nobody else: every cell in the box was walked, every soldier in it examined, and every
one discarded by a side comparison. At two thousand five hundred soldiers that was some
three million wasted examinations per tick, and it showed up as target selection still
holding four fifths of the soldier loop after the bound was in place. Reading one byte per
cell instead of walking a bucket of seventeen soldiers took the same battle from 794 ms of
soldier loop to 58 ms.

The mask is set in the same place membership is, so there is no second invariant to keep
true. It stores a bit per side rather than a single "this cell is occupied" flag because
the whole point is to answer "is the side I want in here", and a cell holding only the
other army is the case that was costing the time.

## D-069: The scaling work stayed in GDScript

**Decision.** The spatial grid, the bounded target search, the overlap rewrite and the
focus cache are all GDScript. No threads, no GDExtension, no ECS, no MultiMesh, no physics
broadphase.

**Why.** The brief for this milestone asked for exactly that and gave the reason: threading
a bad algorithm hides it temporarily and makes determinism harder, and C++ remains an
option for *measured* hot paths only. What was measured was a quadratic pair of loops, and
removing a quadratic term is an algorithmic change that a faster language would not have
made. So the language was left alone until the algorithm was right.

What is left after that change is worth recording, because it is what a future decision
about GDScript would be made against: at five thousand soldiers a tick costs a few tens of
milliseconds, and the dominant phase is overlap resolution - a per-soldier local query
whose candidate count scales with how many soldiers share a cell, which on a fixed
battlefield grows with the army. That is a *density* limit rather than a language limit,
and the honest next question is whether the battlefield should grow with the army before
anyone asks whether GDScript is fast enough.

No GDScript-hostile architecture was introduced either: soldiers remain plain data, a
formed soldier's per-step work is a reference and an array read, and the per-soldier cost
that remains is measured rather than asserted.

## D-070: The grid's bucket tails are persistent storage, not a per-rebuild allocation

**Decision.** `BattleSpatialGrid` keeps its bucket-tail array as grid storage, sized and
cleared alongside the bucket heads, rather than creating one per rebuild.

**Why.** `rebuild()` brought a destination it was writing into back to zero by allocating
a fresh `PackedInt32Array` every time. That is small, it is bounded by the cell count
rather than by the army, and it was invisible in every benchmark — and it made a comment
in the same file untrue. The grid's cost model is "one linear pass writing into
preallocated arrays", and a claim that is *nearly* true is worse than one that is not
made: the next person to reason about the grid would have reasoned from it and been
wrong, and the per-rebuild allocation is exactly the kind of thing that hides until a
rebuild happens a thousand times a second.

The fix is three lines. The verification is the part worth keeping: a test runs five
hundred rebuilds and asserts that static memory grew by less than a page, which would
fail loudly if a per-rebuild allocation ever came back. A comment cannot fail.

## D-071: The separation pass counts what it did, not only what it cost

**Decision.** `BattleOverlapGrid` carries counters — cell pairs considered and skipped,
soldier pairs measured, touching pairs, clamped displacements, largest displacement,
settled soldiers, interior cells — collected only when profiling is on.

**Why.** The profile clock from Step 7.2 said the separation pass was 66% of a tick at
five thousand soldiers. That is enough to know it matters and not nearly enough to know
what to do: "eighty per cent of the phase is spent walking candidates that turn out to be
far away" and "most of it is spent resolving genuine contacts" call for opposite
responses, and the clock cannot tell them apart.

The counters could. Measured before any restructuring: **95.6 candidates per soldier**,
226 touching pairs army-wide, and the broadphase itself 62 to 66 per cent of the phase.
Twenty-one hundred candidates measured per candidate that mattered. That number is what
selected the architecture, and it was not reachable by reading the code — every line of
the old pass looks reasonable.

The counters cost two array writes and a comparison when they are on and a boolean test
when they are off, and they are off in gameplay.

## D-072: An explicit attack order is resolved before the automatic search, not after it

**Decision.** `_update_unit()` resolves a soldier's explicit attack order first, and only
runs the automatic target search if the order is absent or has lapsed.

**Why.** Step 7.2 asked the battlefield for the nearest enemy and then threw the answer
away whenever an order was in force. The order is authoritative whenever it is valid,
which is most ticks of most ordered soldiers, so that was a per-soldier local search
performed for no reason — and since Step 7.2 bounded the search, it is not free.

The semantics are identical: the order is honoured while its target is a living enemy and
lapses the moment it is not, in the same tick either way. What changes is only who does
the work first. A regression test asserts both halves directly — an ordered soldier
ignores a nearer enemy, and goes back to the nearest living enemy the tick its order
target falls.

## D-073: The separation pass gets its own index with its own cell size

**Decision.** Overlap resolution no longer uses `BattleSpatialGrid`. It uses
`BattleOverlapGrid`, a second index over the same battlefield with its own cell size from
`battle.overlap_cell_size` (0.9 world units), and the two grids coexist for the length of
a battle.

**Why.** The two systems ask questions of completely different sizes. A target search
starts at 8 units and wants to be generous; a separation happens at
`separation_radius * SEPARATION_FACTOR`, which is 1.35 units. One cell size cannot serve
both: 4-unit cells are right for a search reaching eight units and far too coarse for a
distance of one and a third, and the measurement showed exactly that — the pass was
handed a box several times the width of the distance it cared about and discarded 99.95%
of it.

Sharing one index also meant sharing one rebuild, one margin, and one set of semantics
for two jobs that want different ones. Separating them removed the second rebuild per
tick as well: the targeting grid is now built once, where the soldiers are, and never
reconstructed for the separation pass.

The class is a separate file rather than a second configuration of the same one because
the *pair production* differs, not just the numbers. `BattleSpatialGrid` answers "who is
near this soldier", one query at a time, because that is what a target search needs.
`BattleOverlapGrid` enumerates cell against cell, because a separation pass wants every
pair once and does not want a query per soldier or a result array to go with it.

## D-074: Overlap pushes are accumulated and applied together, and that is a deliberate change

**Decision.** Every overlapping pair contributes half a separation to each soldier's
accumulated displacement; the field is moved once, at the end of the pass. Step 7.2
pushed each pair apart the moment it was found.

**Why.** Step 7.2's pass was sequential: the second pair of a cluster was measured
against positions the first pair had already changed. That makes the outcome depend on
the order pairs are visited in, which is why Step 7.2 had to reproduce the exhaustive
loop's visit order exactly to get the same positions, and why its test compared positions
against that loop. Preserving a visit order is possible; it is not free, and it is a
constraint that every later change has to keep satisfying.

A simultaneous pass has no visit order to preserve, because every soldier reacts to where
everyone stood. That is a stronger guarantee than reproducing one, and it is why the
order-independence test can reverse the entire roster and check that nobody's position
moves by more than a thousandth of a unit. A claim about iteration order that is
undone by reversing an array is not worth much; this one survives it.

**What is honestly different.** This is not the same relaxation. A sequential pass
resolves a cluster harder in a single tick than a simultaneous one, because each soldier
sees the corrections already made to its neighbours. The two reach the same separated
arrangement, but a simultaneous pass takes more ticks over it — measured on a
deliberately pathological pile, two hundred passes leave under two per cent of the
original overlap and the closest pair back out at 91% of the separation distance. For a
battle that is the right trade: soldiers are separated at least as fast as they can walk
into each other, which is tested directly, and the slow tail only appears in a crush no
formation produces. Where a battle does press bodies together, the pass keeps up.

**What is not a change.** Every soldier is still simulated, enemy contact is resolved by
the same code as friendly contact, and no pair is skipped that could be touching.

## D-075: A soldier can be shoved by at most one body's width per pass

**Decision.** The displacement a single separation pass may apply to one soldier is capped
at `battle.max_separation_push` (1.35 world units, the separation distance).

**Why.** A soldier buried in a crowd takes a push from every body it is inside, and those
pushes are summed. Nothing in the arithmetic bounds that sum, so a dense enough pile can
displace one soldier by ten units in one tick — a launch, and a launch is the difference
between a simulation that looks like a battle and one that looks like a physics bug. One
separation distance is more than any single separation needs, so the cap cannot slow an
ordinary push down; it only ever binds when something has gone badly wrong, which is
exactly when it should.

Two tests hold it: twenty soldiers stacked on a single point each move no further than
the cap, and a four-hundred-soldier crush moves nobody further than ten caps over ten
passes.

## D-076: Formation geometry is the primary mechanism for friendly spacing

**Decision.** The separation pass skips cell-against-cell work where every soldier in both
cells is standing within `battle.separation_settle_epsilon` (0.15 world units) of the place
its formation gave it *and* both cells belong to the same formation *and* that formation's
slot spacing exceeds the separation distance plus twice the settle distance.

**Why.** This is the architectural statement the milestone is built around:

> Formation geometry is the primary mechanism for maintaining normal friendly soldier
> spacing. Spatial overlap resolution is a local corrective system for genuine physical
> conflicts and contact, not a substitute for formation geometry.

Soldiers standing on their slots are already separated by construction — a slot grid's
closest two places are one spacing apart, and a spacing is 2.6 units against a separation
distance of 1.35. Asking the separation pass to rediscover that every tick, for every
pair, is doing the same arithmetic twice; the first time was when the slots were laid out.

The skip is taken on a proof rather than a heuristic, and the proof is checked three ways
before it is taken: both cells must be uniformly settled, they must be the same body, and
the body's own spacing must clear the requirement with room to spare. A cramped formation
does no skipping. A body with one soldier out of place does no skipping in the cells that
soldier touches — which is the interesting case, and is tested by putting a soldier inside
one of its own neighbours and checking that the pair is then found and separated.

**What it must never do** is apply across two bodies. Two friendly formations touching or
crossing are a real physical event — a reserve advancing through a gap, a line passing
behind another — and every pair between them is measured, settled or not. Enemy contact is
the same code on the same terms. The tests for both are the ones that matter most here.

## D-077: Two benchmark families, because one battlefield cannot answer both questions

**Decision.** The benchmark reports two families. **Family A** is the fixed-area torture
test, unchanged from Step 7 in seed, dimensions, layouts, tick budget and rules, so that
every number remains comparable across three milestones. **Family B** scales the
battlefield with the army so that density stays at the 500-soldiers-on-100x60 reference
(0.0833 soldiers per square unit) and the standard 5:3 aspect, with armies deployed as
formed bodies that start standing on their slots and advance into contact.

**Why.** Family A answers "what happens if an army is packed into a space far too small
for it", which is a genuinely useful question — it is the stress case a uniform grid is
worst at, and it caught the density limit that Step 7.2 reported. It is not the question
"what does a battle of twenty thousand soldiers cost", because past a few hundred
soldiers the field stops being a battlefield and becomes a crowd: at twenty thousand, the
soldiers do not fit in it dressed.

Family B is the realistic one. It is also the only place where the formation-aware
skipping of D-076 can be seen at all, because family A's armies never stand on their
slots — its formations are created at a centroid and the soldiers walk towards them for
the whole measured window.

**What neither family reports.** Rendering. Both step the simulation directly. Both say
whether contact was reached, and family B says how many ticks were spent fighting, so an
approach measurement is never offered as the cost of a battle.

## D-078: The separation cell size is one body's width, and it was chosen by measurement

**Decision.** `battle.overlap_cell_size` is 1.35 world units - the separation distance
itself, `separation_radius * SEPARATION_FACTOR`. It is a separate config value from
`battle.spatial_cell_size`, not a fraction of it, and a sweep is what chose it.

**Why 1.35 and not something else.** The neighbourhood radius is derived as
`ceil(separation distance / cell size)`, so the cell size decides how many cell offsets
each occupied cell has to walk. Making the cell exactly the separation distance gives a
radius of one: a cell is paired with the four cells in front of it and no further, which
is the smallest neighbourhood that can still be correct. Anything smaller needs a wider
neighbourhood and pays for offsets that cannot contain a touching pair; anything larger
packs more soldiers into a cell and pays for pairs that are measured and discarded.

Measured on the fixed-area benchmark, total milliseconds per tick, same seed and budget:

| `overlap_cell_size` | 2,500 soldiers | 5,000 soldiers |
| --- | --- | --- |
| 0.45 | 140.8 | 356.3 |
| 0.70 | 138.1 | 350.1 |
| 0.90 | 141.8 | 345.2 |
| **1.35** | **128.4** | **326.5** |
| 2.00 | 138.5 | 349.6 |

The margin is not enormous - of the sizes tried, the worst is about ten per cent slower
than the best - but the winner is also the size with a *reason*, which is worth more than
a tuning number that happens to be fastest. One cell is one body's width; a cell is
paired with the cells around it and nothing more.

**What happens if the separation distance changes.** Nothing breaks. The reach is derived
from both numbers at the start of every pass, so a separation distance that no longer
matches the cell size produces a wider neighbourhood and the same correct answer, just
more slowly. The value would then want re-sweeping, and the sweep is four commands.

**Why it is not derived automatically.** It could be - `separation_radius *
SEPARATION_FACTOR` is right there at start-up - and for one milestone it would have been
the tidier choice. It is a config value instead because it is a *performance* decision
that happens to equal a *physical* number today, and the two are not the same kind of
thing. When ranged combat arrives and somebody wants a separation pass tuned for a
different crowd, the number should be adjustable without changing what a body is.


## D-079: Target handling was counted before it was changed

**Decision.** Target acquisition was instrumented before it was altered - searches run, where
the answer came from, why a remembered opponent was dropped, how many candidates a look
measured, how long a soldier went without an opponent - and the counters, not the phase
clock, chose what the milestone would attack. Every counter is incremented behind
`profile_enabled`, so a real battle pays nothing to be explained.

**What the counters said.** They were run twice: once against the unmodified Step 7.3 code
(the tip of that milestone with the counters added and nothing else changed) and once
against the shipped build, both at the same seed, layout and 150-tick windows. Counters are
rates per soldier-tick, so they compare directly:

| Soldiers | Step 7.3 looks/tick | Step 7.4 looks/tick | 7.3 looks per soldier per second | 7.4 looks per soldier per second | avoided |
| --- | --- | --- | --- | --- | --- |
| 500 | 500.0 | 54.6 | 20.00 | 3.28 | 89.1% |
| 2,500 | 2,500.0 | 409.4 | 20.00 | 4.91 | 83.6% |
| 5,000 | 5,000.0 | 925.6 | 20.00 | 5.55 | 81.5% |

And what those looks were doing at five thousand soldiers: **4,095 of 5,000 found nobody at
all**, and the 5,000 between them measured a candidate 71.8 times to return one answer - so
roughly two candidates in eighty-one named a soldier worth naming.

**Why it mattered that the counters came first.** The phase clock said "target selection
costs 248 ms a tick", which is equally consistent with "the search is slow" and "the search
happens too often" - and those call for opposite fixes. The counters said the question was
already cheap and asked sixty-six thousand times a second to be given an answer that had not
changed. A reading of the code could not have decided it either way, because every line of
the old search is reasonable; only counting what it *did* decided it.

**What is counted.** Looks, successful looks, empty looks, rung counts for the escalation
ladder, the cheap focus path (and how much of it was reached by proof rather than by a
soldier's turn), explicit-order uses, retained-tick counts split by whether the opponent was
in reach, invalidations split by cause, immediate versus scheduled reacquisitions, candidates
per look and the worst look, opponent changes, and acquisition latency in ticks. They
partition soldier-ticks exactly - a test asserts the five paths add up to the number of
soldier-ticks simulated - because a set of counters that overlaps cannot be added up.


## D-080: An automatic target is a persistent engagement, and awareness is staggered

**Decision.** A soldier's automatic opponent is remembered between ticks. Once acquired it
stays the answer while it is alive, hostile and still within `battle.target_retention_radius`
of the soldier. A soldier looks around again when that stops being true, or when its own
awareness tick comes round, and never merely to rediscover that the enemy in front of it is
still standing there.

The awareness tick is a simulation tick counter (`BattleUnit.next_search_tick`), and the
phase a soldier starts on is `unit.id % battle.target_reacquisition_ticks`. Both are integers,
both are derived from data the battle already has, and no clock of any kind is read to decide
when a soldier looks.

**Why persistence.** Step 7.3's profile said target selection was 248.542 ms a tick at five
thousand soldiers - 66% of the tick - because every soldier asked the battlefield who was
nearest to it, every tick. The question was already cheap, because Step 7.2 made it local;
what was expensive was asking it sixty-six thousand times a second to be told the same
answer. A soldier in a fight is dealing with an enemy it can see, and the tick that
discovers "still there" is a tick bought and thrown away.

**Why a staggering rather than a global slowdown.** The obvious way to ask less often is to
ask every fourth tick, and the obvious way to implement that is `tick_index % 4 == 0`. That
turns a smooth cost into a sawtooth: three cheap ticks and one that costs four times as much.
Phasing on the unit id spreads the same work evenly, keeps every tick the same shape, and
makes the schedule a property of the *soldier* rather than of the moment - so re-ordering the
roster cannot move it, and a re-run reproduces it exactly. A test asserts that: the same
soldiers in the reversed order look on the same ticks.

**Why simulation ticks and not a clock.** Everything about a battle in this project is
reproducible from a seed: the same orders must produce the same fight, tick for tick, and the
determinism test compares the whole target sequence between two runs. A scheduler reading
`Time.get_ticks_msec()` cannot promise that, because the wall clock is not part of the
battle's input. Wall-clock timing remains where it belongs: inside the benchmark's counters,
behind a boolean, measuring rather than deciding.

**What it costs.** Responsiveness, bounded and measured. A soldier that loses an opponent
while it could have struck it reacquires in the same tick (D-083); a soldier that loses one
that was never in reach waits at most one cadence, and the tests measure that bound at every
cadence the sweep covered. What it does not cost is a player order: an explicit attack order
is resolved before the automatic path is reached at all (D-085).

**What it is not.** Not a reservation system, not a threat table, not an aggro table, not a
squad assignment, and not a per-unit timer node. It is one integer of memory and one integer
of schedule on a struct that already exists for the duration of a battle, and both are
battle-transient: no campaign save ever sees them.


## D-081: The cadence is four ticks, and the switch margin is a quarter

**Decision.** `battle.target_reacquisition_ticks` is 4 and
`battle.target_switch_advantage` is 1.25. Both were swept on the fixed-area benchmark at
2,500 and 5,000 soldiers with the same seed, layout, tick limit (120) and budget, back to
back on one machine.

The cadence, at five thousand soldiers:

| cadence (ticks) | looks per soldier per second | target ms/tick | total ms/tick | 2,500 total |
| --- | --- | --- | --- | --- |
| 1 (every tick) | 13.57 | 174.402 | 280.559 | 86.452 |
| 2 | 6.79 | 93.756 | 200.397 | 69.476 |
| 3 | 4.52 | 66.498 | 173.012 | 63.828 |
| **4** | **3.39** | **52.825** | **160.079** | **61.260** |
| 6 | 2.26 | 39.389 | 146.134 | 58.225 |
| 8 | 1.70 | 32.322 | 139.951 | 56.437 |

**Why 4 and not 1.** One is the behaviour the milestone replaced, and it is measurably the
worst column: **3.3 times the target cost of four**, and the widest spread between the average
tick and the worst one (D-084).

**Why 4 and not 8.** Eight is cheaper - 12.6% of the tick at five thousand soldiers in this
window, against 8.7% for six - and it costs 350 ms of worst-case awareness latency instead of
150 ms. The sweep's returns diminish quickly after four (the target phase falls by half again from 4 to
8, but the *total* by an eighth, because the target phase is no longer most of the tick), while
the latency a soldier pays for it grows linearly and without limit. Four ticks is a sixth of
a melee swing; eight is nearly two fifths. The value is a config knob and this table is the
reason it is four, not a number somebody liked.

**Why 1.25 for the switch margin.** Hysteresis exists so that two enemies at similar range do
not exchange the answer on alternate ticks, and the margin is how much closer a new candidate
has to be to take over. Measured churn at the shipped value, at five thousand soldiers in the
fixed-area fight: **47.8 opponent changes a tick across five thousand soldiers** - about one
change per soldier per hundred ticks - and zero in a test where two enemies stand three and a
bit units away for forty ticks. A margin of 1.0 would switch on any difference at all, which
is what the old every-tick rule did; a much larger margin would start ignoring enemies that
have genuinely come closer, and the milestone's own test pins both ends: a hair closer is not
a reason to change, and an unmistakably closer enemy is.


## D-082: The retention radius is the search ceiling, and the sweep is why

**Decision.** `battle.target_retention_radius` is 32 world units, equal to
`battle.target_search_max_radius` - deliberately equal, and swept before it was chosen.

**The sweep.** Same fixed-area benchmark, 2,500 and 5,000 soldiers, same seed, layout, tick
limit and budget, one run per value. The interesting column is not the milliseconds - it is
what the soldiers *did*:

| retention radius | 5,000 total ms/tick | target ms/tick | releases per tick ("too far") |
| --- | --- | --- | --- |
| 8 | 157.077 | 52.315 | 127.1 |
| 16 | 156.608 | 52.256 | 110.7 |
| 24 | 157.357 | 52.463 | 68.9 |
| **32** | **157.397** | **52.624** | **0.1** |

**What the numbers say.** The time is flat - flat to within half a per cent across the whole
sweep, so the retention radius is not where the milliseconds are. The behaviour is not flat at
all: at 8, 16 and 24 a soldier acquires an
enemy at long range via the second rung of the ladder and then releases it again on the very
next tick, because the radius it will *keep* is narrower than the radius it is allowed to
*search*. A hundred and twenty-seven releases a tick at eight units is not a retention rule;
it is a loop. At 32 - where a soldier can keep anything a search could have found - the
releases fall to essentially zero, and the only opponent that is ever let go is one that has
genuinely walked away.

**Why not just delete the knob.** Because the *release* rule is what stops a soldier running
after one enemy across a battlefield, and it needs a finite number to do that. The knob is
also what a future pursuit or ranged milestone will turn, and its meaning is now clear:
how far a soldier will continue with an opponent it already has, regardless of how far it
may look for a new one.


## D-083: Urgency is one rule, and it is a loss taken inside the soldier's own reach

**Decision.** Exactly one situation can bring a search forward off the cadence: a remembered
opponent that has stopped being valid *and* was within the soldier's own reach when it
stopped. It is on by default (`battle.target_immediate_on_contact_loss`), it is measured in
both positions, and it is the only off-cadence path in the milestone.

A loss at a distance - an opponent that walked off, or one that was never in reach, or any
loss when the rule is switched off - waits for the soldier's own awareness tick like
everything else.

**Why that rule and not "always immediate".** Always-immediate is what the milestone removed:
it makes the search rate proportional to the *death* rate rather than to the schedule, and
deaths come in bursts. The narrow rule keeps the responsiveness where a player can see it -
the melee line, where a soldier whose opponent just fell should not stand over the corpse -
while a soldier that was marching towards somebody it had not reached yet has nothing to
react to.

**What bounds it.** The size of the contact line, not the size of the army: only soldiers
whose opponent was within reach can search off-cadence, and those are the ranks actually
fighting. The death-storm benchmark kills an entire front rank of a twelve-hundred-soldier
battle on one tick and measures the tick it lands on against the thirty ticks of ordinary
fighting before it; the storm tick costs a few per cent more than the average and the tick
after it is cheaper again. The figures are in the milestone report.

**And the API the brief anticipated was not added.** A cheaper narrow question - "does this
nearby region contain a hostile soldier?" - was expected to be needed for an
immediate-versus-deferred decision. It was not: the two questions the new path asks are "may
I continue with the opponent I have" (an id probe and a distance) and "is it within my reach"
(a distance), and the one query-shaped decision - whether a loss was taken mid-swing - is a
distance against a corpse. Adding a method nobody calls would widen the grid for nothing, so
`BattleSpatialGrid` is unchanged by this milestone apart from a comment recording that
decision. Measurement decides what to add, and here it decided against.


## D-084: Every tick is sampled, because the average is not the evidence

**Decision.** The benchmark can sample every phase on every tick (`--spikes=1`) and report
the average, p50, p95, p99 and worst case. A staggered schedule is exactly the kind of system
that can average well and spike - three quiet ticks and one expensive one - and the average
of such a system is a number that hides its own defect.

**Why it was needed here.** The question the milestone had to answer was not "is the cadence
cheaper on average" but "does staggering flatten the ticks or sawtooth them", and those are
different measurements of the same run. At five thousand soldiers on the fixed-area field,
same seed, same window, milliseconds per tick for the whole tick:

| cadence | average | p50 | p95 | p99 | worst | worst / average |
| --- | --- | --- | --- | --- | --- | --- |
| 1 (every tick) | 281.102 | 194.409 | 659.079 | 690.166 | 713.892 | 2.54x |
| **4 (shipped)** | **159.043** | **139.720** | **247.364** | **255.819** | **258.250** | **1.62x** |

And the phase this milestone attacked, sampled the same way:

| cadence | target average | target p50 | target p95 | target p99 | target worst |
| --- | --- | --- | --- | --- | --- |
| 1 (every tick) | 173.152 | 91.603 | 559.090 | 590.106 | 610.120 |
| **4 (shipped)** | **52.255** | **31.490** | **149.717** | **158.498** | **159.589** |

The tail is where the cadence pays most. Both configurations are measured over the same
battle and both have a long tail, because the tail is the battle itself - the tick on which
the armies meet - but the every-tick baseline is two and a half times its own average at the
worst tick, and the staggered schedule is one and a half times its own. In absolute terms the
worst tick of the battle falls from **713.892 ms to 258.250 ms**, and the worst target tick
from 610.120 to 159.589 ms. The spread the milestone is most likely to have introduced is the
spread it measurably reduced.

The same instrument answers the question the brief asked about synchronized bursts: the
phases are sampled per tick, so a system that saved work on five ticks out of six and spent
it on the sixth would show up as a p50 far below its average with a p99 far above. It does
not.


## D-085: Target handling is a hierarchy, and the nearest enemy is only the last question

**Decision.** A soldier's opponent for a tick is resolved in a fixed order, cheapest first:

1. **An explicit player order.** Resolved before anything automatic, honoured whenever its
   quarry is a living enemy, and never delayed by a cadence, a retention rule or a search
   bound. A soldier holding an order does not advance its awareness clock at all.
2. **The remembered opponent**, while it is alive, hostile, and within the retention radius.
   If it is also within reach this is the end of the matter, and the tick cost nothing.
3. **A search**, when the soldier has nobody worth continuing with or when its own awareness
   tick has come round. The search is unchanged from Step 7.2.
4. **The formation's or the side's focus**, which is the answer the bodies have already
   worked out for themselves once this tick, and what a soldier outside the fighting is
   pointed at.

**What this deliberately changes.** Step 7.3 asked for the nearest local enemy every tick, so
a soldier always faced whoever was marginally closest, and a soldier with an enemy in front
of it re-derived that fact sixty-six thousand times a second. The new rule is:

> Once a soldier acquires an automatic opponent, that opponent remains preferred while alive,
> hostile and locally relevant. Reacquisition happens immediately on invalidation, or
> according to a deterministic staggered awareness cadence, or when the soldier's own turn
> comes round - and an explicit player order outranks all of it.

The differences are three, and they are behavioural rather than cosmetic:

- **A soldier does not switch to a marginally nearer enemy.** Hysteresis
  (`battle.target_switch_advantage`, 1.25) means a new candidate has to be a quarter closer
  to take over. Two enemies at similar range no longer swap the answer on alternate ticks,
  which is both cheaper and less twitchy to watch.
- **A soldier faces the enemy it was dealing with rather than recomputing.** For a formed
  soldier this only changes facing, because a formed soldier dresses to its slot either way.
  For an unformed one it is the difference between walking at the enemy it engaged and
  walking at whoever is currently nearest.
- **A soldier outside its own search bound may be pointed at its body's fight rather than its
  own nearest enemy.** That was already true in Step 7.2 (D-067); the bound is the same and
  the rule is the same, but the skip in D-087 means the wide look that used to happen first
  no longer runs when it provably cannot find anybody.

The search itself is untouched: `_nearest_local_enemy()` answers exactly what a whole-field
scan answers inside its bound, ties to the lower id, and is still the function the
brute-force equivalence tests drive. Step 7.4 changed how often that answer is asked for,
never what it says.

**Why the order matters.** Every step in the hierarchy is cheaper than the one below it, so
the order *is* the optimisation. A soldier in a melee - the common case in a real battle -
never reaches step 3. A soldier marching towards a fight reaches step 4 and stops there.


## D-086: Awareness is a capability a unit declares, not a weapon it is carrying

**Decision.** `BattleUnit.awareness_radius` is how far a unit looks for its own enemies, zero
meaning "use the battle's configured ladder". The retention radius is derived from the same
number (`max(search radius, battle.target_retention_radius)`), so a unit that can see further
also keeps what it finds further off.

**Why it exists while there are no archers.** Step 8 does not start here, but the brief is
explicit that this architecture must not assume a one-point-eight-unit melee reach: target
validity and reacquisition have to work from reach, capability and configured awareness
rather than from what a unit is. So the four decisions the target path makes - how far to
look, how far to keep, whether a target is within reach, whether a look is worth making - are
all expressed in terms of a unit's own numbers, and nothing anywhere in the path branches on
`unit_type_id` or on `ranged`.

**How it is pinned.** Two ways, both in `tests/test_target_acquisition.gd`. A source scan
asserts the simulator contains no code-shaped weapon check (`"archer"`, `unit_type_id ==`,
`ranged ==`). And a behavioural test gives a unit a wider awareness, checks that it finds an
enemy a standard soldier cannot see, and separately checks that two soldiers with identical
stats but different type names behave identically. A future ranged milestone changes the
radius, not the algorithm - and if it ever needs a special case, it has to delete a test to
get it.


## D-087: A look that can be proved to find nobody is not made

**Decision.** Before a soldier searches, it checks whether a search could possibly return
anybody, and if it cannot, the battlefield is not asked. The check is a bound, not a
heuristic:

```
d(soldier, E) >= d(anchor, E) - d(soldier, anchor) >= focus_distance - offset
```

The body's focus is the enemy nearest to the body's anchor, at a known distance; the soldier
stands a known distance from that anchor; so if `focus_distance - offset` is already beyond
the widest rung of the soldier's ladder, no enemy is inside it and every candidate the query
would have measured was outside the radius it could return. The grid's own query margin is
subtracted, because both the focus and the soldier may have moved by up to the distance the
fastest soldier can walk since the focus was computed.

**Why it was needed.** Removing the repeated looks revealed what had been hiding behind them.
Once the soldiers with an enemy in reach stopped searching at all, the searches that remained
were *self-selected for being expensive*: a soldier with nobody within eight units escalates
to a thirty-two-unit query, which on a dense field walks hundreds of cells to hand back
candidates that are nearly all beyond the radius. The wide look of a rear-rank soldier
marching towards a battle it cannot reach is the clearest example of the waste: it cannot
find anybody, and the formation's own focus already knows where the fighting is.

**Why a proof and not a threshold.** A threshold would be a behaviour change dressed as an
optimisation. This is not: when the bound holds, the search would have returned nothing and
the soldier ends up pointed at its body's focus either way. The answer is identical; only the
question is skipped. A test drives a formed battle for two hundred ticks, and for every
soldier whose look was skipped checks *every enemy on the field* to confirm that none was
inside the soldier's own bound.

**What it is like.** The settled-interior skip of the separation pass (D-076): the same
"prove there is nothing there, then decline to look" shape, taken on arithmetic rather than
on a guess, and asserted by a test rather than described in a comment. The two together are
the pattern to reach for when a phase is dominated by work that cannot change an answer.


## D-088: The formation-focus path was counted before it was changed

**Decision.** Before a line of Step 7.5 was written, the focus path was instrumented with
counters - where each question came from, how many whole-army walks it cost, and what each
answer was - and the milestone was chosen from what they said rather than from reading the
code.

**What the counters said**, at twenty thousand soldiers on the scaled battlefield, one hundred
bodies:

| | per tick |
| --- | ---: |
| focus evaluations | 100.0 |
| whole-army walks (`_nearest_enemy_to_point`) | 109.5 |
| of those, made on behalf of a *soldier* | 9.5 |
| soldiers walked by those walks | 2,189,412 |
| soldiers answered straight from their body's focus | 12,318.9 |
| focus answers that changed from the previous tick | 36.3 |

The phase cost **760 ms of a 1,786 ms tick** in that run, which is the 881 ms of the Step 7.4
report re-measured with the counters in place on this machine. An earlier run of the same build
put the phase at **856 ms of a 1,940 ms tick**; it was measured into a temporary file that the
machine has since cleaned up, so it is recorded here as corroboration rather than as the figure
of record - a number that cannot be re-read is not evidence. The several runs agree to within a
per cent on the counts and within about a tenth on the phase cost, which is the spread of the
same battle measured over different windows; none of them is another's correction.

**Why it was needed.** The phase clock could say that formation focus cost most of a second.
It could not say whether to make the pass smaller or to stop the pass from happening so often,
and those are different fixes. Reading the code said *one pass over the army per body per
tick*, which is 100 x 20,000 = 2,000,000 soldier-visits, and the counters confirmed it to
within the repairs at 2,189,412. They also found something reading the code had missed: **9.5
of those walks a tick were made from inside the soldier loop**, on behalf of a single soldier,
because a body's answer that died mid-tick was recomputed by whoever noticed. That work was
billed to the target phase, where Step 7.4 had just spent a milestone making things cheaper - a
hidden cost of the previous milestone's own optimisation.

**What it settled.** The architecture follows from the measurement, not from taste: the
expensive pattern is *one whole-army walk per question*, so the fix is to ask one question per
body and answer every soldier from it. It also set the ceiling for the fix - the new selection
may not contain a path that walks the army, or the milestone would have moved the cost rather
than removing it. `foc_scans_from_soldiers` is the counter that proves it, and its expected
value is now zero.

**What it is like.** D-079, one milestone earlier and one level up: the counters again chose
the architecture, and again the honest figure was the count of questions rather than the cost
of one. The difference is that this time the counter also found work the phase clock had been
attributing to somebody else.


## D-089: Formation battlefield awareness is calculated at the formation layer

**Decision.** Every body keeps a transient battlefield summary - living count, centre, and an
axis-aligned box around its living soldiers - rebuilt once per tick, and every body's focus is
chosen by comparing *bodies* rather than soldiers:

```
one pass over the bodies   -> every body's summary from its own roll
one pass over the army     -> the side totals, and the soldiers no body claimed
per body                   -> the nearest unopened box, then the soldiers inside it
```

The focus is still the soldier a full scan would have named. What changed is the order of the
questions: the nearest hostile soldier to a body's anchor belongs to a body whose box is
nearer than any other body's, so the body is found first and its nearest member second.

**Why it is exact rather than approximate.** The distance from a point to a body's box is a
lower bound on the distance from that point to any soldier in it, so a body whose box is
already further away than the best soldier found *cannot* hold a nearer one. Candidates are
opened nearest-box-first and the loop stops the moment the closest remaining bound is beyond
the best candidate, which proves nothing left can beat it. Ties go to the lower unit id in both
implementations, so the answer does not depend on the order soldiers happen to be met in. It is
asserted rather than argued: `tests/test_formation_focus.gd` drives live battles and compares
the bounded selection against `_nearest_enemy_to_point` body by body and tick by tick,
including with the lines in contact.

**The second half of the pass is conditional.** The walk over the army exists for the soldiers
nobody claimed - the ones with no body, and the side totals that a soldier with no body is
pointed from. A deployed army has none: every soldier is in a body, so the walk had nothing to
find and was pure cost. It now runs only when the number of soldiers the bodies counted does
not match the number the battle believes are standing, and a battle with no unformed soldiers
pays one comparison instead. Measured at twenty thousand soldiers, that single change was
22 ms of the 55 ms focus phase on the scaled battlefield and 15 ms of 49 on the fixed-area
one - the largest single saving of the milestone after the architecture itself, and it came
from asking what the walk was for rather than from making the walk faster.

The count it compares against is kept up as soldiers fall rather than counted, which makes it
a hint: if it is ever wrong it is wrong high, and a hint that is wrong high makes the pass do
the walk it would otherwise skip. Nothing downstream can be wrong because of it.

**Why bodies and not a formation-level spatial grid.** With about a hundred bodies in the
realistic benchmark, comparing bodies against bodies is a few thousand cheap comparisons a
tick - a small fraction of the pass it replaced - and the measured cost is dominated by the
summary pass rather than by the comparisons. A grid would add a structure, an invariant and a
tuning constant to make something cheaper that is already a per-cent-level share of the tick.
Family C measures where that stops being true, and the figure is not the one this paragraph
originally guessed: the layer is **13.2 ms at a hundred bodies a side** (a real battle's count),
**58.8 ms at two hundred**, **242 ms at four hundred** and **2.37 seconds at a thousand** - the
selection is quadratic in bodies, and at 400 a side the reference implementation it replaced
costs **1.11 seconds on its own**. So the grid is not justified today and the curve says what
would justify it: a future milestone fielding several hundred bodies a side. A structure, an
invariant and a tuning constant are not worth building against a share of the tick that is
below one per cent at the count the game actually uses.

**Why there is no retention rule.** The brief allows one and the measurement declines it. A
body's answer changes 38 times a tick across a hundred bodies, which is the answer changing
rather than the pass being wasteful, and the pass now costs a fraction of what it did - so a
hysteresis rule would be new behaviour bought with no measurable saving. The honest statement
is that recomputing is cheap now, and a rule that changes when a body changes its mind is a
tactical change, which this milestone is not.

**What it is not.** No nodes, no per-soldier objects, no ECS, no GDExtension, no threads. The
summary is a handful of numbers on the body and one array of soldier references on the
battlefield, rebuilt from the soldiers every tick rather than being state that can go stale.

**The reference-cycle trap, recorded because it was hit.** The first version kept the focus
soldier *on the body*. A soldier already points at its body, so a body pointing back at a
soldier is a reference cycle, and Godot's reference counting has no collector to break one: the
test run ended with 110 leaked objects and the engine saying so at exit. The focus soldier now
lives in one array on the battlefield, indexed by the body's position in the formation list,
and the body holds only numbers - an index, a distance, a tick. The suite's leak check is part
of what a milestone has to pass, and it caught this one.

**Membership is read from the body's own roll, not from the soldier.** The summary pass counts
a body's soldiers from `unit_ids` - the list that is the authority on who is in a body - and
then walks the army once for anyone no body claimed. That is what makes
`remove_units`/`remove_unit`/`set_units` safe to call directly: a detached soldier stops being
counted by the body it left immediately, and is counted as a loose soldier of its own side
rather than becoming invisible to the focus layer. Membership changed by an API the body owns
cannot leave a stale summary, whichever API a caller reaches for.


## D-090: A death is corrected at the level that owns it, and nowhere else

**Decision.** When a body's focus soldier dies after the pass has been made, the next soldier
in that body to ask causes one correction for the whole body. The correction is the same
bounded selection, not a walk of the army. A body whose focus was found to be *nobody* is not
asked a second time in the same tick, and neither is a side.

**Why the second half is not an optimisation but a necessity.** Nothing comes back to life
inside a tick, so a second answer to "is there anybody left" is the first answer, and the cost
of asking again is proportional to the army. Without the guard, a side wiped out at the top of
a tick becomes a selection per soldier for the rest of it - the O(N x bodies) shape the
milestone exists to remove, wearing a different hat. It is the one place where Step 7.5 is
stricter than Step 7.4, and it is stricter only in work that cannot change an answer.

**Why the first half is kept as eager as it was.** A repair that succeeds is what keeps a body
pointing at a living enemy, and the old code did it per soldier because it was expensive either
way. It is not expensive any more - one selection over bodies, and one body's soldiers - so the
behaviour is preserved rather than traded away.

**The counter.** `foc_scans_from_soldiers` counts whole-army walks made by the focus logic on
behalf of a soldier. In the measured battles it is **zero**, and its previous value is on
record: 9.5 walks a tick at twenty thousand soldiers, 189,412 soldier-visits a tick, billed to
the target phase where nobody was looking.

**What it is like.** D-083's rule, one level up. That milestone decided a soldier whose
opponent was taken away mid-swing may look off its schedule; this one decides that the same
event is dealt with once for the body. Contact urgency stays a soldier-level fact and the
correction stays a body-level one, which is the hierarchy working as intended rather than as a
diagram.


## D-091: The hot path allocates nothing, and says so with a number

**Decision.** Every buffer the focus path needs is allocated when the army is handed over and
reused. The candidate list, the taken stamps, the per-side loose-soldier arrays, the per-body
focus arrays and the per-body member arrays are sized once - in `add_units` and
`add_formation` - and a tick writes into them rather than building them. `foc_allocations` counts every allocation the path can
make; a test drives sixty ticks after the army is built and asserts the count does not move,
then adds a body and asserts that the one thing which does allocate is counted.

**Why it needed measuring rather than asserting.** "This allocates nothing in the hot path" is
the sort of claim that is true until somebody adds a `duplicate()` to a loop, and GDScript
gives no cheap way to see it from outside. Reading the code and believing it has already been
wrong once in this milestone: an early version of the counters kept a `PackedInt32Array` per
body that `reset_profile` emptied without re-sizing, and the resulting index error ended the
focus pass early rather than failing loudly. The counters are now sized by the same helper as
the arrays they belong to, so a reset cannot leave the pass shorter than its data.

**Local accumulation, not object state.** The summaries are accumulated in local variables and
handed to the body once per tick. Writing a `Vector2` component onto an object in GDScript is a
read, a modify and a write, and the pass does it per soldier - ten thousand times a body per
tick on the torture test. Measured, that was worth about a fifth of the focus phase.

**The member arrays, and why they exist.** The first version of the selection walked a body's
soldiers by resolving each id through the battle's unit dictionary. That is correct and it is
the wrong shape for a hot path: on the fixed-area torture test, where a body is ten thousand
soldiers, it was 40,000 dictionary lookups a tick, and the milestone's focus phase measured
*more* expensive there than the pass it replaced. Keeping references to each body's living
soldiers in a reused array - the same shape as the spatial grid's own snapshot index - removed
the lookups and with them the regression. Recorded because "read the ids from the body" is the
obvious implementation and it was measurably worse than the thing being replaced.

**What was deliberately not done.** No scratch pooling framework, no allocator, no
`PackedVector2Array` rewrite of the summaries. The largest remaining per-tick allocation in a
battle is the events array every attack appends to, which is not this milestone's cost; the
focus path's own figure being zero is as much as this milestone should claim.

## D-094: The target search was left alone, because every cheaper one measured slower

**Context.** Step 7.5 ended with a profile that named the next bottleneck unambiguously: on the
realistic twenty-thousand-soldier benchmark, automatic target acquisition cost 575.1 ms of a
965.5 ms tick - 57% of the simulation and 85% of the soldier loop - while formation focus, the
phase just fixed, had fallen to 41.6 ms. Step 7.6 set out to attack that 575 ms with an exact
re-implementation of the local search, and a target of a three-fold cut.

**What was measured before anything was changed.** The path was counted, not guessed at, over
about two hundred ticks at each of five, ten and twenty thousand soldiers - 193 at five thousand,
which the run's own totals give exactly: 192,088 looks at 995.3 of them a tick. At twenty thousand a tick ran
**2,438 looks** - not the 5,000 that a cadence of four would imply - and a look cost **212 us**
inside the grid query (45 us in the first rung, 167 in the second), which the phase timers put
at **86.1%** of the whole 601.3 ms target phase. One look made **1.77 grid queries**: one per
rung of the escalation ladder, **23% answered by the first rung, 44% answered after widening,
32% answered by nobody at all**. Per look the ladder read **260 cells** and handed over **171
candidates** to be measured so that one of them could be kept. The second rung was 78% of the
query time.

(The same profile taken over the twenty-tick window that the before-and-after comparison uses
agrees throughout - 1.71 queries, 243 cells, 174 candidates, 71% of looks escalating, 86% of the
phase inside the query - and differs where a difference is expected rather than in noise: the
shorter window is the opening approach, the longer one spans the contact era too, so
more looks are answered from memory or by the formation and fewer reach the second rung. The two
are quoted as their own windows rather than averaged.)

**The diagnosis the milestone started from, and the one it finished with.** The starting
assumption was that the *traversal* was the problem: that a walk which opens each cell once,
stops when no unopened cell can improve the answer, and never materialises a candidate list
would be several times cheaper. Five exact implementations of that idea were written and
measured, in a micro-benchmark built for the purpose (`scripts/dev/search_bench.gd`) and in
live battles:

Four of the five were run in a live battle, by running the whole realistic sweep on that
implementation and reading the target phase out of the profile. The benchmark was used
differently and more narrowly: to isolate *why* the shipped path is cheap, not to score each
candidate - the in-grid method kept the name `nearest_hostile` through every rewrite, so no saved
benchmark log attributes a figure to a named candidate, and the earlier forms were measured in
console runs that were not saved. What the saved logs do contain is the shipped path and its
isolates:

| saved benchmark figure | log |
| --- | ---: |
| the whole ladder's look, at approach and in contact | **46 - 64 us** (`bench_iso.txt`, `bench_final_contact.txt`) |
| one radius-32 box walked with no candidate list | **226 - 235 us** |
| one box of the new walk, alone | **277 - 308 us** |
| the ladder's second rung collected and scanned flat | **314 - 344 us** |

**The battle column is what the milestone decided on, and every figure in it is in a saved log:**

| implementation | shape | live battle, 20K target phase |
| --- | --- | ---: |
| Chebyshev ring walk | cells opened ring by ring outward from the soldier | **2.64x** (1,638.1 ms) |
| row walk, index order | rectangle pass with per-row reach windows | **3.20x** (1,988.0 ms) |
| row walk, nearest rows first | the same, rows and columns outward from the soldier | **2.82x** (1,749.2 ms) |
| rectangle walk with a cell bound | one distance test per cell before its bucket | not run in battle |
| block-indexed walk | a coarse 4x4-cell side mask walked before the cells | **3.73x** (2,318.4 ms) |

The per-candidate benchmark ratios quoted in this milestone's working notes (1.5x - 2.6x, 1.9x,
1.8x - 2.1x, 2.3x, 3.3x) are **not restated here**: four of the five came from console runs whose
output was not kept, and the fifth describes a walk whose isolate was timed under a different
name. They pointed the milestone in the right direction and they agree with the battle column, but
they cannot be re-read, and a figure that cannot be re-read is not evidence.

**The battle column is quoted against one reference**: the ladder's 621.1 ms target phase at
twenty thousand soldiers, measured in the same session, on the same build, with the same matched
windows. A second ladder run in that session measured 598.5 ms, so any row above could be
quoted 3-4% higher by choosing the other reference - the spread is the machine's, not the
search's, and it is why every ratio here is stated with the figure it came from rather than as a
bare multiple. The benchmark column spans a range where two placements were measured, because
the ratio moves with packing: a uniform scatter leaves whole blocks empty and flatters a
pruning walk, while packed ranks are what a battle actually looks like.

The benchmark and battle columns disagree, and the reason is worth stating rather than
averaging: the benchmark times one query against a warm index, while a battle times two and a
half thousand a tick against an index that is rebuilt every tick. The per-query ratio is a
floor, not the whole story, which is why the battle figures are the ones the milestone was
decided on.

Every one of them inspects *fewer* cells and fewer candidates than the ladder - the best of them
read 122 cells and measured 45 candidates per look against the ladder's 260 and 171 - and every
one of them is slower. The isolation run says why. One radius-32 box, asked about every query
point on a twenty-thousand-soldier field at realistic packing, costs:

| implementation of the same single query | time |
| --- | ---: |
| the locked path - `collect_within` plus the flat nearest loop over the list it built | 344.5 us |
| the new walk - one rectangle pass keeping the best as it goes, no list | 306.8 us |
| the whole locked *look*, which is the same box preceded by a radius-8 one | **63.2 us** |

Two different walks of the same ground land within 12% of each other, and the full ladder - the
same outer box plus a small inner one - is **five times cheaper than either**, because nine looks
in ten are answered by the inner box and the outer one is never walked. That is the finding:
**the box is the cost, not the way the box is walked**, and no traversal that still walks it can
win. (The standalone-box figures ask the box about every point, including points in the contact
zone where it holds nearly six hundred candidates; they compare two implementations of one query,
which is what the isolation was for, and they are not the ladder's second-rung population.) In
an interpreter a bound test in a loop body costs about 0.3 us and the empty cell it skips costs
about 0.12 us to open and dismiss, so a walk that prunes per cell pays more for the pruning than
it saves on the skipping. Pruning pays only where it lives in the loop bounds, and the cheapest
loop bounds are the ones a rectangle already has.

**Decision: the search is unchanged.** No re-implementation is shipped. The ladder's staging - a
small first rung that answers most looks, widening only for the looks that find nobody - is
already the right architecture for this cost model, and its blunt loops are the cheapest form
the language offers. The blocks-and-rings version was discarded with the block-level mask it
needed - an addition on top of the per-cell side mask the grid has carried since Step 7.2.

**The per-cell mask is not a leftover, and removing it is not free.** It was mistaken for
remnant code while this milestone's revert was audited, and the removal was measured before it
was believed. Delete the mask - the one that costs a write per soldier per tick in the rebuild -
and the realistic twenty-thousand-soldier target phase goes from **602.7 to 2,776.3 ms/tick**,
the tick from 995.7 to 3,126.0 ms, and the torture family's total from 1,138.6 to 3,349.0 ms.
The spatial query costs 55.8 us per look with it and 173.1 without, while the rebuild gets 4.9 ms
cheaper: about four hundred times the cost for the write. The mask is why a look that finds
nobody is cheap - in the approach, a cell holding only one's own side is skipped by its bit
instead of being walked and its soldiers rejected one at a time. The removal was reverted and
the tree restored to the locked shape; the measurement is kept here because it says something
the milestone's own figures cannot: **the search this milestone chose to leave alone is not a
bare ladder. It is the ladder plus a Step 7.2 cell mask, and that mask is worth more than
anything the five re-implementations could add.**

**What ships instead, and why it is not nothing.** The instruments that produced the finding,
and they are the milestone's deliverable: the search-shape counters (queries per look, cells read
and cells repeated, candidates split by rung, escalations, the distance an answer was found at,
exact per-search percentiles), per-rung query timings, and per-sub-phase timings for the rest of
the target loop - deciding whether a remembered opponent is worth keeping, deciding whether a
look is worth making, the hysteresis, and answering with the formation. The split is what makes
the milestone's conclusion checkable by anyone: at 20,000 soldiers the grid query is 85% of the
target phase and everything around it is 15%, so any future attempt on this phase can be judged
against the same numbers. `scripts/dev/search_bench.gd` keeps the two box measurements that
outlived the milestone.

**What remains expensive, and what would be needed.** The second rung: a 67x67-unit rectangle
walk taken by 70% of looks, ~300 us each, ~510 ms a tick at twenty thousand soldiers. Nothing
cheaper is available *exactly* in this language - that is the measurement - so the options are
to stop asking the question (a formation-level proof that a soldier's neighbourhood is clear,
which the bucket hierarchy of D-089 is too coarse to give in contact) or to change what the
answer is allowed to be (a bounded search whose bound is the formation's own focus distance,
which is not equivalent and is therefore not this milestone's to make).

**Consequence for the milestone.** `STEP 7.6 CANDIDATE: NO`. The phase it was scoped to reduce
is unchanged; what the milestone produced is the measurement that says why, a cheaper search
than the ladder being, as far as five attempts and a purpose-built benchmark can tell, not
available in GDScript at this scale. Every existing behaviour is untouched: the same suite, the
same battles, the same numbers as Step 7.5, plus the instruments.

## D-095: The target search's spatial kernel moves native, on one measured condition

**Context.** Step 7.6 ended by leaving the target search alone: five exact GDScript
re-implementations had all measured slower than the ladder in place, and the profile said why -
one radius-32 box costs what it costs however it is walked. What that milestone did *not*
answer is the question this one asks: at twenty thousand soldiers the target phase is ~602 ms of
a ~1,045 ms tick, the spatial query inside it is 85.7% of that, and ~85% of the *query* turned
out to be the candidate scan - one distance test per candidate per look, in GDScript, against
live positions.

**Two boundary shapes were built and measured, because the boundary is the question.**

- **Shape A - broadphase only.** The accelerator walks the cells and returns the candidates; the
  exact distance test, the liveness recheck and the tie-break stay in GDScript. Exact by
  construction, because live state never leaves GDScript. Measured at 20K: target phase 591.27 ->
  546.16 ms/tick, total 996.65 -> 954.51 ms/tick, **1.04x**. Almost nothing: the walk it replaces
  is only ~45 ms of the query, because Step 7.2's cell mask already made it cheap (D-068). The
  2,438 looks a tick hand back ~170 candidates each, and paying to move those across the
  boundary costs most of what the walk cost.
- **Shape B - broadphase and the exact test.** The accelerator answers the whole query and
  returns one slot number. Nothing crosses per search. The price is live state: the kernel holds
  positions and liveness, so the battle mirrors its two mutation points into it - a soldier's
  movement (`_move_toward`) and a soldier's death (the killing blow) - and the mirror is proven
  by comparison, not by review. Measured at 20K with the same matched windows: target phase
  591.48 -> 99.49 ms/tick (**5.94x**), total 1,004.88 -> 525.51 ms/tick (**1.91x**), and at
  1,000 / 2,500 / 5,000 / 10,000 the total falls 1.73x / 2.00x / 2.20x / 2.20x. The grid phase
  itself gets *worse* (35.02 -> 44.31 ms/tick) because a tick now pushes its snapshot and
  mirrors its movements across the boundary, and that cost - about 9 ms a tick at 20K - is
  bought deliberately.

**Decision: shape B ships, and native code is allowed exactly here.** The threshold the project
set for itself was a kernel at least twice as fast and a tick at least a quarter cheaper, with
no behavioural difference, no pathological spikes and no regression at normal sizes. Measured:
5.94x and 48% cheaper at the primary size, better at every smaller size, 0 disagreements in
83,669 queries over 29.9 million candidates in live battles, and no spike introduced (see the
spike table in `docs/CURRENT_STATE.md`). Shape A is kept as a mode because it is the shape whose
exactness is structural, and it is the cheaper one to reason about if the mirror is ever
suspected.

**What is native and what is not.** Native: building the cell index from a per-tick snapshot,
walking it, filtering by side and liveness, the exact squared-distance test, and the lower-id
tie-break - `NativeTargetQuery` in `native/`, about 300 lines of C++. GDScript, unchanged: every
other decision in the target path - the ladder's staging and ceiling, the D-087 proof, retained
opponents, hysteresis, cadence, explicit orders, formation focus, the query margin, and which
backend is in use. `BattleSpatialGrid` keeps the locked walk as `_collect_reference` and is the
reference, the oracle and the fallback.

**The determinism contract.** The accelerator must return the answer the GDScript reference
returns, on the same battle state, for every query - and the project checks that rather than
asserting it. `Backend.COMPARE_FULL` runs both implementations on the same rung of the same
ladder and records the first disagreement with the tick, the asking soldier, the position, the
radius and both answers. The suite (`tests/test_native_query.gd`) compares candidate sets over
generated layouts, boundary cases, deaths after the rebuild, movement after the rebuild, dense
and tied cells, and runs whole battles both ways - the accelerated battle must reproduce the
reference's survivors, health, positions and targets unit by unit. Two real defects were caught
by these modes during development and neither reached a benchmark: a radius that silently
included `query_margin` (caught in a live battle at tick 15: the reference found nobody at the
ceiling and the accelerator found a soldier just beyond it), and a counter call that threw once
per query while profiling (caught as a 34x slowdown that was 34x of error handling, not of
kernel).

**Native code in Project Banner is an accelerator for proven hot data-processing kernels, not a
second gameplay architecture.** GDScript retains orchestration and gameplay semantics unless
profiling demonstrates a narrower native boundary is necessary.

**Any native battlefield accelerator must preserve the locked deterministic result of its
GDScript reference implementation.** Performance alone is not grounds for changing tactical
outcomes.

**Where native code is still not allowed.** This decision is not a licence to move anything else.
Nothing else has been profiled to the point where a boundary is justified, and moving work with
live-state coupling means mirroring its mutation points - which is a correctness liability paid
for with proof, not a free speed-up. A future candidate must bring its own profile, its own
measurement of the boundary, and its own comparison mode.

**Family A - the fixed-area torture field - says the same thing, and finds the crossover.**
Matched twenty-tick windows, reference against shape B: at 100 / 500 soldiers the total is
1.82 -> 1.89 and 9.36 -> 9.88 ms/tick (**0.96x and 0.95x** - the snapshot and the mirror are paid
for a search that costs almost nothing), and from 1,000 up it is 1.76x / 1.99x / 2.22x / 2.27x /
1.95x, with the target phase 4.25x to 7.12x cheaper at every size above the crossover. So a
battle chooses its backend **once, before the first tick, by the size of the army it is about to
run**: below `BattleSimulator.TARGET_NATIVE_MIN_UNITS` (1,000, where the measurement changes
sign) the reference answers and the accelerator is not consulted at all; at or above it, the
accelerator does. Nothing switches mid-battle. The threshold is a measured cost boundary, not a
rule about battles - the two implementations agree on every answer either side of it.

**Limitations, stated plainly.**

- The mirror is only as complete as the mutation points it knows about: the tests assert the
  current two, and a static guard in the suite fails if the count of position writes in the
  battle path ever changes without the list being updated.
- The accelerator's cell order matches the reference's because it is fed the same cells, not
  because it recomputes them; `_sync_native` is not optional for exactness.
- A tick that never rebuilds (a battle that has not started) cannot be answered natively;
  `can_answer_natively()` is false until the first rebuild, and the reference answers.
- The release library is the one every run loads, including headless ones, and that is
  deliberate (see `native/README.md`).
- Twenty thousand soldiers is still an engineering stress target: at ~525 ms/tick it is ~1.9
  simulation ticks a second, not a playable battle, and none of these figures are rendering.

## D-096: A profiler counter's name is a claim, and two of them were false

The Step 7.8 audit found two mistakes in the separation pass's own instrumentation, and both were
the kind that produce a confident wrong answer rather than an obvious one.

**`dev_coincident` counted the wrong thing.** It was incremented for every touching pair, before
the test that distinguishes a coincident pair (distance squared at or below `1e-7`) from an
ordinary overlap - so the counter that was supposed to say "soldiers are stacked exactly on top
of each other" was saying "soldiers are touching", which the counter beside it already said.
Anything read from it ("coincidence is common", "the coincident branch is worth optimising")
would have been about the wrong set of pairs. The increment now lives inside the coincident
branch, and two assertions in `test_overlap` pin the difference: one ordinary overlap increments
touching and not coincident; one pair in exactly the same place increments both.

**`dev_usec_pairs` was declared, reset, and never assigned.** The comment above it promised
pair-loop timing; the pass never gave it one and `report()` never printed it, so a reader looking
for where the phase's time went found a zero that looked like "no work" rather than "not
measured". A number that can only ever read zero is worse than no number: it is a claim of
absence. It is gone, replaced by five clocks that are all written - rebuild, same-cell traversal,
neighbour traversal, apply, and the whole pass as the pass itself timed it - with the exact pair
work measured by subtraction (three passes over one frozen field, with the arithmetic left out)
rather than given a column that would have to be apportioned.

**The rule this leaves behind.** Counters partition or nest explicitly, and every field a report
prints is assigned somewhere in the code that produces it. `test_overlap` asserts the partition
for the settled proof (five ways to fail plus one way to pass add up to the cell pairs that
reached it), asserts that a pass with nothing to do reports having done nothing rather than
holding the last pass's numbers, and asserts that with `stats_enabled` false nothing is counted
at all.

## D-097: The settled-cell skip never fired because a real fight has no settled soldiers

Step 7.3 built the pass's one optimisation - skip the cell pairs a formation's own spacing already
proves cannot be touching - and the first Step 7.8 profile found it firing **zero times** at every
size. The question was whether the proof was broken or whether the state it needs is rare, and the
two have opposite fixes: one is a bug, the other is a fact about battles.

Instrumenting the proof's five rejection reasons, and counting them **over every tick of the
battle rather than on the last one**, answers it. (The first pass's zero was partly an artefact of
when it looked: the last tick of a battle is the one tick at which nobody can be settled.) On a
realistic field, over whole battles:

| units | cell pairs / tick | skipped / tick | skip rate | of the pairs that reached the proof |
| ---: | ---: | ---: | ---: | --- |
| 5,000 | 8,284 | 6.5 | 0.08% | 98.2% cell A not settled, 1.4% cell B not settled, 0.4% different body, 0.0% spacing too small, 0.1% proved |
| 20,000 | 32,535 | 54.8 | 0.17% | 95.3% cell A not settled, 3.8% cell B not settled, 0.7% different body, 0.0% spacing too small, 0.2% proved |

So the answer is the second one. Soldiers stand on their assigned places for ~4.8% of a
5,000-soldier battle and ~8.5% of a 20,000-soldier one - the dressing and approach - and the skip
does fire there, which is where it saves the pass from comparing every pair of a body against
itself. Once bodies move and fight, the settle test fails almost every time, which is what the
proof says and what the code says.

**The proof was not weakened to raise the number.** Nothing about `separation_settle_epsilon`,
slot spacing, formation movement, the arrive epsilon or the compression rules was touched: the
skip is allowed only where the existing physical proof holds. The instrumentation was the change,
and the finding is that the optimisation is worth keeping for the phases it does apply to and
worth nothing at contact - so the milestone's effort went where the time actually is, in the pair
loop itself.

## D-098: Packed GDScript: the same pass, 2.3-3.7x faster, bit for bit

`BattleOverlapGrid`'s pair loop reads through objects: `_units[slot]` per pair, then
`unit.position` twice, each constructing a `Vector2`, before any arithmetic happens.
`BattleOverlapGridPacked` copies the field into packed arrays during the rebuild and runs the same
arithmetic over those reads.

Three properties make it a candidate rather than an experiment:

- **The arithmetic is the same, not similar.** Positions are stored as the exact doubles a
  `Vector2` component converts to, and the push accumulators stay `PackedFloat32Array` with a
  per-pair write - batching the pushes into locals would be *more* precise and therefore no longer
  comparable.
- **The enumeration order is kept**, so the floating-point sums match as well as the mathematics.
- **The oracle proves it**: 1,500 generated states against the locked reference, bit for bit.

Measured, matched windows: 3.3x the reference's overlap phase at 20,000 on the torture field, 2.3x
on a realistic field, and it takes the whole tick down by a quarter. It ships as the **portable
fast path**: above `OVERLAP_PACKED_MIN_UNITS` (500) a battle uses it whenever the native library
is not built, which is what makes the fast path available to anyone who clones the repository and
runs it.

## D-099: The separation pass moves native as shape C, on a measured threshold

Shape C is the shape Step 7.7's lesson dictates: the kernel does everything - its own cell index,
its own same-cell and neighbour-cell enumeration, the exact squared-distance test, the coincident
branch, the push, the accumulation and the clamp - and returns **one displacement per soldier per
axis**. GDScript packs the field once, calls once, applies the displacements to units it owns.
Nothing per pair crosses the boundary, and nothing per soldier crosses it twice.

Ownership is unchanged and strictly weaker than the targeting kernel's: the overlap kernel holds
no `BattleUnit`, no formation, no battle rule and no persistent state, so it has no live-state
mirror and no mutation points to keep true. No native state enters a save.

**The boundary is priced, not assumed.** At 20,000 soldiers, per tick: packing the field 32.5 ms,
the kernel's own compute 2.3 ms, applying the returned displacements 8.2 ms - 43.0 ms of round
trip for a 2.3 ms computation, and still 5.6x cheaper than the 238.0 ms the reference pass costs
on the same field. A kernel that computes in 20 ms but costs 70 to marshal is not a 20 ms
solution; this one's marshalling is the larger half of its cost and it is still the fastest pass
available by a wide margin.

**The crossover is measured, not borrowed from the targeting kernel's own 1,000.** The native pass
beats the reference at every size measured (2.6x at 100 soldiers on the torture field, 3.6x at
1,000 on a realistic one) and beats the packed pass at every size, so the threshold is not where
native stops winning but where it starts carrying a meaningful share of a tick:

| units (family B) | reference | packed | native |
| ---: | ---: | ---: | ---: |
| 1,000 | 6.215 ms | 4.266 ms | 1.731 ms |
| 20,000 | 237.990 ms | 103.282 ms | 42.686 ms |

`OVERLAP_NATIVE_MIN_UNITS = 1000`, where native is 3.6x the reference's phase and takes a fifth
off the whole tick - deliberately the same number the targeting kernel uses, so the project has
one "this is a real battle now" line rather than two. Selection happens **once, before the first
tick**, from the army size: never mid-battle, because a battle that changed its separation pass
half way through would be a battle whose performance nobody could attribute. `PB_OVERLAP_BACKEND`
forces one pass, which is what the benchmark and CI use.

## D-100: A formed 300 v 300 battle stalemates, and it is not the separation pass

The pre-optimisation showcase the brief asked for - three hundred men a side, three bodies each,
production settings, windowed, with a live performance overlay - reached contact, fought, and then
**froze**: 302 casualties in the first ~260 seconds of battle time, and then no more casualties at
all, for as long as the battle was allowed to run. Raising the battle clock from the production
600 seconds to 3,600 changed nothing (no deaths for 2,500 seconds). Re-running the same field on
the pre-7.8 build reproduces it exactly.

The mechanism is measured rather than guessed: at the freeze, **0 of 298 survivors had a living
enemy inside their reach** (the peak had been 40 of 590 at contact). The survivors stand on the
rigid slots their bodies gave them, holes included, and once the ranks have thinned the nearest
living enemy is simply further away than any melee reach. The rule that exists for exactly this
case - a body that is not in contact closes the whole way - requires a body that has *stopped*,
and an engaged body steering towards an anchor inside the enemy line never stops; it reports
`moving` forever. So nothing closes the gap, and the two armies stand a few metres apart until the
clock runs out.

**What this milestone did about it: nothing, deliberately.** It is a formation-layer behaviour, it
is not caused by the separation pass, it was not weakened or hidden to make the showcase look
better, and it is recorded here so that whoever fixes it starts from a measurement rather than
from a screenshot. The showcase's own report - screenshots, reachability per stage, physicality
probe - is the evidence.

**Resolved by Step 7.8B (D-101, D-102).** The mechanism above was reproduced headlessly, tick by
tick, and turned out to be two defects nested inside each other: a body with nobody in contact
steered at the enemy's *anchor*, so the two centres were driven onto each other and the surviving
ranks ended up interleaved on one lattice exactly one spacing apart - outside every melee reach;
and the body then reported itself `moving` on a residual its own centre could not express, which
permanently disabled the one rule that could have restarted the fight. Both are fixed at the
formation level, the reproduction is now a test (`tests/test_battle_hardening.gd`), and the same
300 v 300 battle fights to a decision: **seed 780780 resolves at tick 12,222 (611.1 s), 596
casualties, 4 enemy soldiers standing, longest silence in the whole battle 24 ticks, zero stall
windows - and eleven seeds all resolve by annihilation with zero stalemates.** Under the production
600-second clock this battle is now cut off eleven seconds *before* that decision, with both armies
still trading blows (the last one 23 ticks before the cut); the clock is no longer ending a freeze,
which was the whole complaint. The history above is kept because the measurement in it is what the
fix was built from.

## D-101: An engaged body's station is where the surviving fronts meet

**Decision.** `BattleSimulator._engage_target_for()` places an engaged body's station at
`max(0, own_surviving_front + enemy_surviving_front) + contact_gap` in front of the hostile
centre, where a body's *surviving front* is the forward-most place in its own slot layout that
still holds a living soldier - measured along the closing direction. A body never steers inside
the enemy's centre, whether or not it currently has anybody in contact.

**Why.** The rule this replaces was two rules: a body in contact stopped a rank's depth short of
the enemy's centre, and a body that had lost contact closed the whole way onto that centre. The
first is right for an intact line and wrong for a worn one - the depth it uses is the depth the
body was *deployed* with, so a line whose front rank has been killed holds its centre where a body
of full ranks would have stood and leaves its survivors behind their own dead, one rank short of
every enemy. The second is how the frozen battle got where it did: measured on the 300 v 300
reproduction, the two centres were **0.050003 units apart** with all six bodies reporting `moving`
and nobody within 2.556 units of an enemy. Interleaved at one lattice spacing, just outside a 2.4
reach, neither army could strike and neither could close.

**What it fixes, in the two directions that matter.** For an intact body the new station is
*exactly* the old one - two dressed lines still stand off at the sum of their depths plus the
contact gap, which is why nothing about an un-fought battle changes and no small-battle behaviour
moved. For a worn one it moves forward by one spacing per rank destroyed, so a damaged line walks
its surviving rank into the enemy and keeps fighting; measured in the suite, one killed rank moves
the station in by 2.60 units on both sides. The clamp is what makes the frozen state unreachable:
a body's centre can never be driven inside - let alone through - the body it is closing on, and
the suite asserts that over six hundred ticks of two bodies trying to close on each other with
their front ranks destroyed.

**Cost.** Two walks over a body's own roll per engaged body per tick, on slots already rebuilt for
the movement the same function is about to do. Batch: 20,000 soldiers, same command and window as
the pre-fix build - see the measured before/after in `CURRENT_STATE.md`.

**Reversible?** Yes, and cheaply: it is one function plus one helper, and the old numbers are
recoverable by measuring `(depth + depth) / 2 + gap`.

## D-102: A step the centre cannot express is an arrival

**Decision.** `BattleFormation.advance()` treats a movement that does not change the centre as an
arrival: if the computed step is positive but adding it to `anchor` leaves `anchor` unchanged, the
body takes its station (`anchor = target_anchor`) and `is_moving()` becomes false.

**Why.** `Vector2` stores single-precision components, so at a coordinate of about 104 the smallest
change a centre can hold is ~7.6e-6 units. The frozen battle sat with a residual distance of
**0.050003052** - the arrive radius (0.05) plus 3.05e-6 - and a step of 3.05e-6 is below what the
coordinate can express, so the body could not move, could not arrive, and reported `moving` for
fifteen thousand ticks. That mattered because `is_moving()` is one of the conditions that decides
whether a body's soldiers may press forward to restart a fight that has stopped: the state machine
was not merely cosmetic, it was the gate on the only remaining recovery mechanism. With the guard,
"has this body stopped" is answerable again in every reachable state, including the degenerate ones
D-101 does not remove (two bodies whose survivors are all behind their own centres).

**Consequence.** The centre moves by less than the arrive radius when this fires, so nothing is
teleported and no normal battle's numbers change: a body already within a rounding error of its
station was arriving on the next tick anyway. `tests/test_battle_hardening.gd` drives the exact
frozen numbers - anchor 104.55005645752, station 104.600059509277 - and asserts it arrives rather
than reporting movement forever.

**Reversible?** Yes, one branch, but there is no reason to: without it a body can be permanently
unable to act while claiming to be on its way.

## D-103: The battle runs on a fixed simulation step, and `battle.tick_rate` is that step

**Decision.** The battle scene no longer feeds the simulator the length of the frame it just
rendered. `BattleClock` accumulates real frame time (multiplied by the player's battle speed) and
emits whole fixed-size ticks; the scene runs exactly those ticks and draws the latest state. The
step is `1 / battle.tick_rate`, and `battle.tick_rate` is corrected from 30.0 to **20.0** - the rate
(0.05 s) every benchmark, showcase and suite in this repository has been measured at. One frame may
run at most eight ticks, and a backlog beyond half a second is dropped rather than queued.

**Why.** The scene called `_simulator.step(delta * _battle_speed)` with the render delta, so the
simulation's step size was whatever the last frame took - which means the same seed, the same army
and the same orders produced a *different battle* on a different machine, purely because of frame
pacing. That is not a rendering difference; it is the fight itself. Step 7.8B proved it with a
controlled comparison before changing anything: the same battle stepped at two frame patterns
diverges, and the same battle stepped at one fixed size does not. Determinism is already a load
bearing property of this project - target cadence is counted in ticks, awareness slots are derived
from soldier ids, the whole test suite leans on it - so the runtime had no business being the one
place where it was not true.

**What it deliberately is not.** No interpolation between simulation states, no prediction, no LOD:
a frame draws the state the simulation reached. That is a look rather than a correctness question
and belongs to the milestone that adds it. Nor is 60 ticks/second chosen because rendering targets
60 FPS - one tick is a design decision and it stays a design decision, which is why it lives in the
game data and why the value is the one all the existing measurements were taken at.

**Consequence.** A slow frame runs *more ticks*, not a longer tick: the same enemy does not think
faster on a fast machine. Battle speed (the dev flag and any future UI control) also multiplies
real time rather than the step, so `--battlespeed=8` is now eight times as many identical ticks
rather than one eight-times-larger step. The catch-up cap means a machine that cannot keep up sees
the battle take longer in real time, which is the honest failure mode.

**Reversible?** Yes - one scene call site, one small class, one config value.

## D-104: The surviving front is read off the summary the tick already built

**Decision.** `_surviving_front()` walks the living members the tick's summary pass collected
(`_body_members` / `_body_member_count`) rather than the body's roll, and computes the projection
with the slot's own arithmetic (`lateral * (right . direction) + forward_offset * (forward .
direction)`) rather than by building slot positions and subtracting vectors. The rule therefore
reads membership as of the start of the tick and pays one tick of lag on a death.

**Why.** The first version read the roll, one `_unit_by_id` probe and one `is_alive()` call per
soldier, twice per engaged body per tick. Measured on the final build against the locked tip in
matched thirty-tick windows at twenty thousand soldiers on the torture field, the formation phase
went 36.459 -> **68.205 ms/tick**: +31.7 ms/tick, about 5% of the whole tick, for a question whose
answer the battle had already computed a few hundred microseconds earlier in the same tick. The
summary knows exactly who is alive and where they stand on the roll, so the second walk was pure
duplication.

**What the lag costs.** A rank that is destroyed becomes the body's front one tick later than it
could have, which is a fiftieth of a second of a body's centre not yet having moved - and the
station is a positioning decision taken at the top of a tick, not a combat rule. Nothing about
contact, damage, targeting or the overlap pass reads it.

**Measured, three interleaved pairs, family A at 20,000 soldiers, matched thirty-tick windows:**
before 363.5 / 368.1 / 367.3 ms/tick, after 366.1 / 369.8 / 370.7 - **+2.6 ms/tick (+0.7%)**. The
realistic family B, matched sixty-tick windows: 383.2 / 385.9 before against 393.9 / 393.6 after -
**+9.2 ms/tick (+2.4%)**, with the formation phase itself 36.5 -> 37.3 ms/tick. Both figures come
from runs interleaved with each other on one machine, because this host's twenty-thousand-soldier
numbers move by tens of per cent with CPU state: an earlier set of the same comparisons, taken
while the ten-seed sweep was finishing, read 433-467 ms/tick for the same workloads.

**Reversible?** Yes, and it is the kind of choice that should be re-measured if the roll ever
becomes cheaper to walk than the summary is to read.

## D-105: A body chooses the enemy body, and a soldier only looks when the fight is his

*(Recorded as Step 7.8 / `milestone-07.8c` in the repository's own numbering: the brief that
commissioned this work called it "Step 7.8 - formation-driven engagement", but Step 7.8 is the
locked separation-pass milestone, so the work landed as its own milestone and the locked history
was left alone.)*

**Decision.** A battle body picks the enemy body it intends to fight - once per re-check, by box
distance, with hysteresis, overridable by an explicit order - and its soldiers are allowed to look
for opponents of their own only when the fight could actually be theirs. There are exactly four
ways to be allowed: an explicit order from the player, a blow taken within the last twenty ticks
(and then the soldier strikes back at whoever struck it, which costs one index probe and no
search), standing within a weapon's reach of an enemy body that is close enough to matter, or
having no body at all - a soldier with no body is its own formation and keeps the pre-formation
behaviour exactly.

**Why.** A soldier six ranks back was asking the battlefield a strategic question - *which
individual enemy should I attack* - when its body had already answered the strategic question for
itself: *that body, ahead of us*. The work that remains is local and real: the men who can
actually reach each other still choose their own opponents, keep them across ticks, and fight
them. Nothing about a soldier's individuality changed; what changed is who is asked to search.

**The band comes from weapons, not from swords.** A body's *contact band* is the furthest reach
any of its living soldiers has, plus the same for the enemy body, plus one rank of slack (2.6
units), all of it accumulated by the summary pass that already walks those soldiers once a tick.
A body of archers promotes its men from further off than a body of spearmen, and the promotion
test is a box distance from the soldier to the enemy body's bounds - not a frontage test, because
a formation can be taken on a flank or from behind, and those are exactly the cases where its
soldiers must not be blind. A body watches for enemy bodies within the band plus twelve units
(about two seconds of marching), which is how a flanker becomes something its soldiers may answer
to before it arrives rather than after.

**Struck soldiers strike back without looking.** The damage step records who struck whom. A
soldier that has been hit in the last twenty ticks and has nobody worth keeping strikes back at
its attacker for one index probe. This is deliberately *after* the ordinary resolution, so a
soldier already fighting somebody does not drop that fight because a second enemy clipped it -
which is what stops a melee soldier thrashing between attackers (D-081's concern, one layer up).

**What it costs and what it buys.** At three hundred a side, over nine hundred ticks of the
showcase's own battle, the same seed with the layer on and off in one build:

| | searches | deferrals | soldiers in individual mode |
| --- | ---: | ---: | ---: |
| hierarchy off (the architecture this milestone replaced) | 99,174 | 0 | 560 of 560 (100%) |
| hierarchy on | **20,783** | 109,277 | **168 of 566 (29.7%)** |

At five hundred a side it is **169,738 against 17,112 searches**, with 143 of 962 soldiers in
individual mode - and the reduction grows with the size of the bodies, because the band is a fixed
depth of frontage while the body behind it is not.

**It is switchable, and that is the point.** `battle.engagement_enabled` (or `PB_ENGAGEMENT=off`)
puts the old architecture back, in the same build, tick for tick: with it off the Step 7.4/7.6
target suite passes all 231 of its assertions unchanged, and every benchmark in this milestone is
a pair of runs that differ only in this one flag.

**What it did not touch.** Target retention, the awareness cadence, the search ladder, the
retention radius, the switch hysteresis, the native target kernel, the separation pass, the save
format and every explicit order. The five-path accounting that Step 7.4 established now has a
sixth term - the deferrals - and the invariant that *every soldier-tick is exactly one of them*
is asserted on both sides of the switch rather than weakened.

**The one honest caveat.** The cheap path that answers a soldier from its body's focus
(`_focus_target`) already existed and already answered most soldier-ticks: in the baseline battle
above, 10,908 of 14,400 soldier-ticks in a smaller fixture went through it. What this milestone
removes is therefore *searches*, not focus reads - which is the expensive half, and the half whose
cost grew with the size of the battlefield.

## D-106: A formation is a roll of soldiers, so it can be split and merged at runtime

**Decision.** `BattleSimulator.split_formation(body, ids, new_id)` carves any subset of a body's
roll into a new body of its own, and `merge_formations(keeper, donor)` folds one body into
another. Both are membership edits through the existing `assign_formation`, which takes a soldier
off whatever roll held it before it adds it - so a living soldier is in at most one body by
construction, and `check_membership_invariants()` proves it after the fact rather than trusting it.

**Why this is cheap enough for gameplay.** There is no battlefield rebuild anywhere in it. The
work is a pass over the two rolls, the same pass a body's summary makes every tick, plus the
membership arrays being brought up to date: O(soldiers in the two bodies + bodies), not O(army).
Measured, carving a third off one engaged body and then a third off the next: **0.269 ms a split**
at six thousand soldiers, with zero invariant complaints.

**What a split preserves.** Soldier ids, names, health, kills, damage, equipment and history -
splitting moves rolls, never soldiers. No soldier is created, destroyed, duplicated or lost; the
roster and every id are asserted unchanged across repeated surgery. The new body inherits the
source's type, order, facing and movement intent, then becomes a real independent actor: its own
anchor, facing, layout, order, target body, contact state, cohesion and reform state.

**What a merge does.** The donor's roll is appended to the keeper's in order, the donor leaves the
battlefield, the bodies are re-indexed (the focus and summary arrays are addressed by index, and
an index that no longer means what it did is a stale answer waiting to be read), and any body that
was facing the donor has its target cleared rather than left naming something that is gone.

**The invariant checker.** `check_membership_invariants()` returns a list of sentences - duplicate
membership, a soldier pointing at a body that does not roll it, a slot index that disagrees with
the roll, a body whose living count disagrees with what it rolls, a target body that is gone or
empty, a soldier who believes it is in a body that does not hold it. It builds the summaries
first, so it answers about the battle rather than about when it was asked, and it is a tool rather
than a tick: it walks every soldier. The randomized suite drives two thousand transitions -
splits, merges, deaths, movement, ticks, with random subsets - and asserts the invariants, the
roster, the ids and reproducibility throughout.

**Cohort compatibility.** A body's soldiers are addressed by a roll, a slot index, and per-soldier
state; nothing in this design assumes a body is one indivisible blob. A future Cohort layer is a
sub-roll of the same shape - a list of soldier ids, a sub-block of the layout, its own summary -
and the contact band already works per soldier rather than per body, so partial contact, local
casualty tracking and local target assignment have somewhere to live without moving a soldier.

## D-107: A battle is counted in Roman sizes, and the same group is the unit of display and compute

Project Banner counts its soldiers in the names soldiers actually counted themselves in, because
each one is a size rather than a flourish: the **contubernium** is the eight men who shared a tent,
the **century** is the smallest body that fought as one thing, the **cohort** is the smallest that
could be detached and still hold a line, and the **legion** is a field army. These live in
[code]scripts/battle/unit_scale.gd[/code] ([code]class_name UnitScale[/code]).

The ladder is not decoration. It is the level of detail the battle is *drawn* at - close in, the
soldiers themselves; further out, first the century, then the cohort, then the legion - and it is
also the group that the simulation would work out once instead of once per man. Display and
computation use the same grouping, so a box on screen is a promise about the arithmetic behind it:
the same numbers, not an approximation of them.

Thresholds are camera zooms ([code]SOLDIER_ZOOM[/code] 6, [code]CENTURY_ZOOM[/code] 1.5,
[code]COHORT_ZOOM[/code] 0.6) rather than world sizes, because what matters is how much screen a
mark of a given size covers. [code]PB_BLOCK_VIEW=1[/code] refuses to draw individuals at any zoom,
which is how the large showcases are watched. The men behind the boxes are still persistent
individuals with their own health, kills and experience; only their drawing is grouped.

## D-108: A group is an entity - shared arithmetic for pose and movement, individual state for everything else

The player's instruction: **merge the group into a single entity**, with the box brackets the player
chooses before the battle and the ability to break a group apart at runtime down to a single
soldier. The display half shipped first ([code]UnitScale[/code], D-107): one mark per century,
cohort or legion. This records the other half and the measured case for it.

**What the per-soldier loop actually costs.** Profiled on the 12900K at 30 ticks, profile on, both
armies formed (`pb-bench/entity/phase_2k.log`, `phase_20k.log`):

| phase (ms/tick) | 2,000 | 20,000 |
|---|---|---|
| soldiers (per-soldier update loop) | 20.1 | 198.3 |
| of which choosing targets | 7.3 | 72.0 |
| formations (body steering) | 2.9 | 34.5 |
| grid (broadphase rebuild) | 4.4 | 44.0 |
| focus (engagement) | 3.3 | 35.8 |
| overlap (separation pass) | 3.7 | 45.5 |
| **total** | **37.1** | **388.2** |

Half the tick is the per-soldier loop. A third of that is choosing targets, which is already gated
by D-105 and must stay per soldier because it is a decision. The remaining **~126 ms/tick at 20K -
roughly 6 microseconds per soldier - is pose and movement**: reading a slot, measuring the distance
to it, and stepping toward it. That is arithmetic about where a group stands, done identically by
every man in the group, and it is what the entity merge removes.

**The design.** A group - contubernium, century, cohort or legion, at the bracket the player chose -
holds the shared arithmetic: where it stands, how it is turned, how it moves, how it holds its
shape. Its soldiers keep everything that is theirs: health, kills, experience, their own opponent,
and their own fall. The rigid path is exact rather than approximate: when every man of a group is
dressed, every man's next position is the group's own transform, so the group computes it once and
the numbers are the same numbers. A man out of place falls back to his own step, as he does now.

**The bracket and the structure.** The grouping ladder is the structure: the player sets it before
the battle and can break a group apart into the next level down, at any time, down to one soldier.
Splitting and merging already exist as membership editing (`split_formation()`,
`merge_formations()`, D-106; 0.27 ms a split at 6K) - the entity layer is what makes the groups
worth having, because each one is now one calculation rather than a hundred.

**Constraints this must respect.** The Step 7.8 separation pass is locked and is not altered by
this work; the profile above is the reason the entity merge is worth doing without touching it -
the overlap pass is 45.5 ms/tick at 20K against 198.3 ms for the soldier loop. Every claim is a
matched-window, same-build A/B with the switch off restoring the previous architecture tick for
tick, exactly as D-105 was measured.

## D-109: Right click orders a march to anywhere on the map, not only to a town that can be entered

Travel was settlement-only: an order named a settlement, and anything the player could not *enter*
was refused with "not an enterable location". Most of the map is not an enterable town, so a player
clicking a hamlet, a ruin or a crossroads was told the order was impossible while his party stood
still. That is what "my unit still doesn't move" was.

A destination is now either a settlement or **a point** ([code]destination_point[/code] /
[code]destination_is_point[/code] on [code]CampaignState[/code], both carried by the save, with a
default so an older save loads unchanged). [code]TravelService.set_destination_point()[/code] orders
a march to a spot, [code]destination_position()[/code] is what [code]step()[/code] walks toward, and
[code]_finish_travel()[/code] separates the two endings: a settlement is entered and marked visited,
open ground is simply where the march stops.

**The buttons.** Right click is the move order, and it is the only one: a place that can be entered is
travelled to by its settlement order - so arriving opens it - and every other spot by a point order.
Left click selects, and does not move the party. The HUD names the destination either way, with the
hours it will take.

**Why a point and not a nearest-settlement fallback.** Sending the party somewhere it was not told to
go is worse than refusing the order. The march goes where it was aimed, and the arrival radius says
when it is close enough to count as arrived.


---

---

## D-110: The kill cleanup is measured in a tick, not inferred from a total

**Decision.** Every death walks the entire roster to clear the explicit attack orders that were
hunting the soldier who fell - `BattleSimulator._attack`, "anyone hunting this unit must pick a new
quarry". That walk is O(roster) per death, and it was the last suspected quadratic path inside the
per-soldier update loop, which is the largest measured phase in a large battle. Rather than replace it
on suspicion, the walk is counted: deaths that enter it, roster entries inspected, orders cleared, the
largest single walk, and the walk's own elapsed time.

**Measured, inside ticks the game actually ran** (`scenes/dev/death_storm_probe.tscn`, seed 70909,
one `step()` per row, lines of ordered attackers against one-hit-point enemies):

| soldiers | deaths in that tick | roster entries inspected | the cleanup | the whole tick | the cleanup's share |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1,000 | 388 | 388,000 | 36.3 ms | 46.7 ms | **77.8%** |
| 5,000 | 1,915 | 9,575,000 | 1,027.3 ms | 1,093.5 ms | **93.9%** |
| 20,000 | 7,542 | 150,840,000 | 23,599.0 ms | 24,003.6 ms | **98.3%** |

**And the scaling, measured separately by killing a known number of soldiers** at 20,000: one death
costs 20,000 entries and 4.0 ms, fifty cost 1,000,000 and 194.8 ms, and four hundred cost 8,000,000 and
1,596.9 ms. Entries inspected per death equals the roster size exactly at 100, 1,000, 5,000 and 20,000
soldiers, so the cost is deaths x army and nothing else. Order density barely moves the *time*: the
same storm with no orders, with a tenth of the army ordered, and with every soldier but the victim
ordered at one man measured within a few per cent of each other, because the inspections dominate and
the clears are nearly free - raising the orders cleared at 20,000 from 9,999 to 19,999 left the timing
unchanged.

**Why it matters.** One death in a large battle is invisible (4 ms against a 437 ms tick). A tick in
which the front rank dies is not a hitch, it is the entire tick: at 20,000 soldiers the cleanup is
**98.3%** of it. Twenty thousand soldiers remain a goal rather than a result, and this is now the
best-evidenced reason why.

**An independent audit rejected the first version of this work, and it was right twice.** It found
that the "zero profiling work when profiling is disabled" claim was false - the single-loop
implementation kept a boolean test per roster entry inside the hottest walk in the battle - and that
the "all living units ordered to one victim" workload only ordered one side while its comment claimed
the whole roster. Both are fixed: the cleanup is now two loops, one instrumented and one exactly the
loop it has always been, and the storm orders every soldier but the victim. The audit's third finding
was about the *first* attempt to demonstrate the cost, and it is the reason the numbers above are
measured inside `step()`: a storm whose deaths never pass through a tick cannot claim a share of one,
however carefully the total was summed.

**What is deliberately not done.** The walk is not optimised here. The fix - an order index, so
clearing an order is a lookup rather than a scan of the army - changes a data structure, and this
project's rule is that a measurement establishes the need before an optimisation is written. That
measurement is now in the table above, and the fix is the next milestone with this as its brief.

---

## D-111: The hunters of a fallen soldier are a chain, not a scan

**Decision.** Step 7.9 measured the kill cleanup and found it to be the single most expensive thing in
a large battle: every death walked the whole roster to clear the orders that were hunting the soldier
who fell, which is O(deaths x army) - 98.3% of a twenty-thousand-soldier tick, and 24.0 seconds, on a
mass-casualty storm (D-110). This milestone replaces the walk with a lookup.

**The mechanism.** `BattleSimulator` now keeps an order index: two `PackedInt32Array`s and a head per
unit, sized when the army is handed over so nothing is allocated afterwards. Every soldier holding an
attack order is chained onto the man he was ordered to kill, and the chains are rebuilt once a tick
beside the spatial grid - a snapshot, like every other index in this project, so there is no update
path and therefore no update path to get wrong. A death walks its own chain, re-checking each
soldier's order before touching it, so an order cleared since the chains were built is skipped rather
than assumed away.

**The chains are rebuilt when the tick's index is stale, not only inside `step()`.** The probe and the
suites call `_attack()` directly, and an index built for a different tick - or not built at all - would
have silently cleared nothing, which is exactly the failure mode Step 7.5's focus work hit. A stamp
per tick costs one integer comparison per death.

**Measured, paired, in one build and on one seed** (`scenes/dev/death_storm_probe.tscn`, seed 70909):

| at 20,000 soldiers | Step 7.9 | **Step 7.10** |
| --- | ---: | ---: |
| 50 deaths, no orders | 1,000,000 inspections, 160.5 ms | **0 inspections, 0.011 ms** |
| 50 deaths, every soldier ordered at one man | 1,000,000 inspections, 162.8 ms | **19,999 inspections, 16.2 ms** |
| a storm tick, 7,542 deaths | 23,599.0 ms of a 24,003.6 ms tick (**98.3%**) | **7.6 ms of a 230.1 ms tick (3.3%)** |

The storm tick is **104 times cheaper** and the cleanup's share of it falls from 98.3% to 3.3%. The
cost now follows the *orders*, not the army: one hunter costs one inspection whether the roster holds
ten soldiers or sixty thousand, which is the exact inverse of what Step 7.9 measured.

**The equivalence is proved rather than asserted.** The suite performs the reference scan itself - the
set of orders a full walk of the roster would have cleared - and asserts that the indexed cleanup
clears exactly those, that every hunter's order lapses, and that an order aimed at a soldier who is
still alive does not move. The behaviour assertions from Step 7.9 are unchanged, because the milestone
changed what the cleanup costs and not what it does.

**What did not change.** The order lapses on the same tick it always did. Battle outcomes, targeting
cadence, target-search logic, formation-driven engagement, explicit-order precedence, movement,
separation, balance data, saves, and the locked Step 7.8 overlap optimisation and its native kernel
are all untouched; the only new work in a tick is one linear pass over the roster that a deployed army
pays about nothing for, because it only visits soldiers who hold an order.

## D-112 - the per-soldier loop is counted and priced before it is changed

**Context.** Step 7.9 and 7.10 removed the last quadratic path from the per-soldier loop, leaving it the
largest phase of a tick: 203.1 ms of a 399.0 ms instrumented tick at twenty thousand soldiers in the
fixed-area benchmark, of which automatic target selection is 72.1 ms. About 131 ms per tick was
attributed to nothing.

**Decision.** Count which paths the army takes, price each operation in isolation, and only then name
the fix. Two dev-only instruments, both behind [code]profile_enabled[/code]: per-soldier path counters on
[code]BattleSimulator[/code] ([code]upd_*[/code] and [code]mv_*[/code], reset with the other counters), and a
price probe ([code]scripts/dev/unit_price_probe.tscn[/code]) that times one call of each operation over live
state and a control loop calling an empty function, so the act of calling is separated from the work.

**What the counts say.** At twenty thousand soldiers, per tick: 20,000 soldiers through the loop, 100%
of them resolving a target, 0% already in reach, 100% formed, 20,000 formation-slot lookups, 20,000
moves, 20,000 terrain lookups, and **20,000 calls into the native accelerator** - one per moving soldier,
invisible to any GDScript-side timer.

**What the prices say** (per call, and per tick at those counts): [code]_can_press_forward[/code] 1.4697 us
and **29.4 ms**; the terrain multiplier 0.9422 us and 18.8 ms; [code]formation_slot()[/code] 0.6661 us and
13.3 ms; [code]native_moved()[/code] 0.5441 us and 10.9 ms; the range check 0.2279 us and 4.6 ms; the facing
normalise 0.2071 us and 4.1 ms; and the empty control function 0.2707 us, which is **32.5 ms** of the
total because six such calls happen per soldier per tick. Together: **81.1 ms of the 131 ms**, with the
largest single item a side-contact check nobody had suspected - and that check, read, is six field
reads delivered through four function calls, so what is being paid for is the calling itself.

**Bearing on the locked milestones.** Nothing here changes the game: the counters are inert with
profiling off, the price probe only reads state, and Step 7.8's separation pass and its native kernel
are untouched. The counters and the probe are development-only, under [code]scripts/dev[/code] and
[code]scenes/dev[/code], and a milestone that changes behaviour must delete or switch off anything it no
longer needs.

**Consequence.** The next milestone has a named target instead of a phase name: cache the side-contact
fact per side per tick rather than testing it per soldier, apply the body's own step to the soldiers
already in their places (the rigid-group path widened to dressing, which is where the position,
terrain and slot arithmetic disappear), and mirror moved soldiers into the accelerator in one call a
tick rather than twenty thousand.


## D-113 - the press-forward gate is decided by the body, once a step

**Context.** Step 7.11 measured `_can_press_forward` at 1.4697 us a call - the single largest item in
the per-soldier loop, 29.4 ms a tick at twenty thousand - and reading it showed why: six field reads
delivered through four function calls, asked once per formed soldier per tick, for an answer that is
the same for every soldier in the body.

**Decision.** The gate is decided once per body per step, in the tick immediately after the bodies have
moved and before the soldiers dress (`BattleFormation.press_forward_open`). It holds the two things
that cannot change during the soldier loop: the order test, and the moving, turning and reforming
predicates. That they cannot change is verified rather than assumed - the only call the per-soldier
loop makes into a body is `mark_in_contact`. Contact itself stays live, per soldier, because soldiers
set it part way through their own loop and freezing it would change behaviour in a way that depends on
iteration order. An auditor asked for exactly that distinction and for a fixture that would catch a
regression in it.

**Measured, paired in one build.** `PB_PRESS_CACHE=off` restores the previous code exactly, so the
comparison is a switch in one build and not a comparison against an older log. At 20,000 soldiers on
one seed: the soldiers phase falls from **204.365 ms to 193.643 ms** and the whole tick from
**399.965 ms to 389.244 ms** - **10.7 ms a tick** - with target, formations, grid, focus and overlap
all flat. The recovery is less than the 16-18 ms the probe's per-call price predicted, because the
probe prices a call in a tight loop over two objects while the real loop touches twenty thousand
soldiers between calls: the isolated price is an upper bound and the paired measurement is the number.

**Equivalence is proved, not asserted.** The reference is kept in the same build behind the switch, and
a test drives one showcase battle twice - forty ticks, both commanders thinking - comparing every
soldier's answer, every soldier's position, and the number of soldiers allowed to press forward, on
every tick. The per-tick count is what catches the mid-loop contact case; a frozen contact value would
move one count and not the other. Zero disagreements.

**Not touched.** Movement semantics, iteration order, separation (Step 7.8 is locked), the rigid-group
path (D-108), balance data and saves. The flag is development-facing; the shipped default is on.


## D-114 - the remaining per-soldier cost is call overhead, so remove the calls

**Context.** Step 7.11 priced the per-soldier loop and found that its cost is dominated by *calling*:
six measured calls per soldier per tick, with the probe's control loop pricing an empty function at
0.27 us. Two surviving items were pure overhead of that kind. The native position mirror's guard called
`can_answer_natively()` - three field reads behind a method - once per moving soldier. And
`_effective_speed` reached the ground's movement multiplier through five nested calls
(`_effective_speed` -> `move_multiplier_at` -> `cell_index_at` -> `inside` + `cell_row_at` +
`cell_col_at`) to do one array read.

**Decision.** Where a per-soldier call's reads are unchanged by inlining - no reordering, no new state,
no invalidation - spell the reads out and delete the call. This is deliberately *not* the same thing as
the Step 7.12 slice 1 cache: that one needed a proof that the cached conditions cannot change while the
soldiers dress. These need no proof of immutability because nothing is held: the same fields are read,
in the same order, at the same point in the tick. Each change keeps its previous shape in the build as a
reference (`PB_NATIVE_GUARD=call`, `PB_TERRAIN_FAST=off`), so every before-and-after here is a paired
run in one build rather than a comparison against an older log.

**Measured, paired in one build**, at 20,000 soldiers on one seed, with every other switch at its
shipped default:

| change | soldiers phase, shipped | soldiers phase, reference | saving |
| --- | ---: | ---: | ---: |
| the native guard spelled out | 190.484 ms | 193.639 ms | **3.2 ms a tick** |
| the terrain path collapsed | 169.468 ms | 191.260 ms | **21.8 ms a tick** |

The terrain pair's whole-tick figures were 363.925 ms against 386.830 ms. It was measured twice - once
before and once after the invariant fix described below - and the two pairs agree to 0.3 ms
(21.5 ms then, 21.8 ms now). Grid, focus and overlap stay flat across both pairs; the formation phase
moved about 0.7 ms between the terrain runs, which is drift rather than attribution, so the claimed
saving is the soldiers-phase delta in both rows.

**One invariant the change had to respect, and did.** `test_native_query` counts the write sites for a
living soldier's position in `battle_simulator.gd` and requires exactly three, because D-095's mirrored
positions are only true while every write is known and named. The first version of the terrain change
put a `position +=` inside each branch of the switch - four sites - and the suite failed on it, correctly.
It is now one write statement fed by whichever path worked out the speed, and the count is back to three.

**What is not changed.** The arithmetic: the same reads, the same order of operations, the same guards
for points outside the field, the same fallback when there is no terrain. The mirror still receives a
position for every moving soldier, so D-095's invariant - that those call sites are the only writes of a
live position - is untouched. No balance data, no saves, and Step 7.8's separation pass remains locked.

**Consequence, and the shape of what is left.** Inlining cannot help the two remaining items, because
neither is a call being paid for a constant read: the body transform must be *proved* not to drift
before it may be used, and the native batch replaces twenty thousand boundary crossings a tick with one,
which is architectural work against D-095 rather than a local change. Both are sequenced after these.


## D-115 - the focus answer is dispatch removal, not a cache

**Context.** Step 7.12 removed the per-soldier loop's calls and left the target phase deliberately
untouched, recording that as the line. Step 7.11's price table had put the target phase at 72 ms of a
169 ms loop, and of that, `focus` - the answer a soldier gets when his look is over or was never due -
was 26.8 ms. Reading the formed-soldier path showed why: a soldier in a body asked a question his body
already had the answer to through four calls - `_side_index()`, `_focus_unit_of()`, that function's
`is_focus_current()`, and the unit's `is_alive()` - for what is one array read and two comparisons.

**Decision.** The formed-soldier fast path is spelled out in `_focus_target`: the body's index bound, its
focus currency, the reference read and the liveness check, in those guards' own order, evaluated at the
same point in the tick. Nothing is remembered between calls and nothing is invalidated, so this is
dispatch removal rather than a cache - where D-113 had to prove four conditions constant through the
soldier loop, and D-111 had to build an index, this needs no immutability proof at all. The reviewer's
instruction was to inline the wrapper and dispatch only, and not to fold target selection into a broader
rewrite: the repair path, the side cache, every search and the retention timers are untouched.

**Measured, paired in one build** at 20,000 soldiers on one seed, one switch apart
(`PB_FOCUS_INLINE=method` restores the method chain): the target phase 72.101 ms against 56.410 ms, the
soldiers phase 170.411 ms against 154.531 ms - **15.7 ms a tick** - with grid, formations, the focus
report and overlap all flat. The focus counters are identical between the two runs, which is the same
decision trace the phase numbers imply.

**Proved, not asserted.** The reviewer's standard for this one, since it touches who fights whom, was a
per-tick identity diff. `tests/test_target_acquisition.gd` now drives one formed battle twice - the
switch off for one run, same seed, same fixture, same tick count - and compares what every soldier
carries as a target, whether he is alive, his health and his place to four decimals, plus every body's
watched body, on every tick for twenty-four ticks; and compares how often the focus was asked, answered
from the body, and repaired. Zero disagreements.

**Considered and deferred.** Handing each body's focus answer to its soldiers once a tick, so the ask is
a field read rather than a method's worth of dispatch, was designed and not taken: a repair mid-tick
changes the answer, so the snapshot would need invalidation at the writer, which is a cache with a proof
obligation. The measured need does not justify that yet.


## D-116 - the instrument is measured, and a clean tick is now available

**Context.** The target loop and the soldier loop were instrumented in the D-105 era with per-soldier
`Time.get_ticks_usec()` pairs - about two to three timed reads a soldier a tick on the paths this battle
actually takes. Reading the loop for Step 7.13's next item turned them up, and D-112's own rule for a hot
path is counts, not per-soldier timers.

**Decision.** The four sub-item timers (`tgt_us_retained`, `tgt_us_focus`, `tgt_us_proof`,
`tgt_us_improve`) are gated behind `battle.target_timing_enabled`, off with `PB_TGT_TIMING=off`. The
per-soldier *phase* marks stay, so the phase table - which is what every comparison in this project is
quoted from - is identical with the switch either way.

**Measured, paired in one build** at 20,000 soldiers on one seed: the soldiers phase 156.719 ms with the
timers against 153.107 ms without, the target phase 57.752 against 54.750, the whole tick 352.600 against
**346.275** - so the instrument costs about **6.3 ms a tick**.

**What that means for every number already quoted.** The game never profiles, so the shipped tick has
always been about six milliseconds faster than the instrumented figure. Every *paired* delta in this
project is unaffected, because both halves of a pair carry the same instrument - that is the whole reason
the project measures that way - and the timing pair above is itself the proof. The absolute figures in
this repository's docs, including the ones Steps 7.12 and 7.13 were measured with, are instrumented
figures; read the clean figure as the instrumented one less about six milliseconds.

**An estimate that was wrong, kept beside the measurement.** Predicting the cost from the call sites gave
fifteen to twenty-five milliseconds a tick; the measurement says 6.3, because the sub-item timers fire on
the paths a soldier actually takes rather than on every path. The milestone's method is that a reasoned
number is a hypothesis and a paired run is the answer, so the wrong estimate is recorded rather than
quietly dropped.


## D-117 - the block view draws the tick's boxes, not every soldier every frame

**Context.** Jay's frame for a large battle is a legion in a box: a thousand men are one mark on the
screen, so a twenty-thousand-man battle is a few dozen marks, and the individuals live in the simulation
rather than on the screen. The code already carried the ladder (`UnitScale`: soldier, contubernium,
century, cohort, legion) and the block view (`PB_BLOCK_VIEW=1`), and the game's default renderer is
instanced (`SoldierField`, 2.56 ms a frame at twenty thousand men, D-107).

**The finding.** The block view cost 26 to 28 ms a frame whether it drew two hundred boxes or forty-two,
against half a millisecond for the ground alone. The same cost at both zoom levels is what told the
story: the rectangles were never the cost. `BattleView._draw_groups` rebuilt its boxes from *every living
soldier in the army* on every frame - asking where twenty thousand men stood in order to draw forty
boxes, and asking again on the next frame with the answer unchanged.

**Decision.** The boxes are rebuilt once per tick and cached, keyed on the tick index and the drawing
level; a frame draws whatever is cached. A box is the unit of display and the unit of computation: it
changes when the battle does, not when the screen does. The rebuild also reads the battle's id-indexed
roster (`_unit_slots`) instead of resolving each id through the dictionary, the same preference the
tick's own summary pass already applies.

**Measured on the development machine** (windowed, vsync off, battle frozen after two ticks, 20,000
soldiers, 1600x900):

| block view | before | after |
| --- | ---: | ---: |
| century zoom (200 boxes over 20,000 men) | 27.72 ms - 36 fps | **1.86 ms - 539 fps** |
| cohort zoom (about 42 boxes over 20,000 men) | 26.24 ms - 38 fps | **0.60 ms - 1656 fps** |
| ground alone, for the floor | 0.51 ms | 0.48 ms |

So the picture a twenty-thousand-man battle is meant to be watched at costs about a tenth of a
millisecond more than the empty ground. The remaining cost of a large battle is the simulation - about
290 ms a tick - not the drawing, and the same measurement run live says so: at twenty thousand soldiers
a live frame is almost entirely the tick.

**Pinned by test.** `tests/test_battle_view.gd` (new suite) asserts the once-a-tick rule, that every
living soldier stands inside a box, and that a thinned rank shows as a smaller box. Its first version
failed on its own fixture - it stepped an unstarted battle, so nothing ticked and the boxes rightly
stayed still - which is the difference between the rule being tested and the rule being assumed.


## D-118 - the native mirror's writes cross the bridge once per flush, not once per soldier

**Context.** Step 7.11 priced the native mirror at 0.998 us a call on the `NATIVE_FULL` backend - about
twenty milliseconds a tick at twenty thousand movers. Step 7.13's proposal to hand each soldier his
body's answer was bounded before it was built: it can only remove the focus sub-item, measured at
15.4 ms instrumented, while the retained-target check (8.5 ms) and the due-look pipeline stay per soldier.
That bound put it under the reviewer's own switch line ("if the measured result lands under about 20 ms,
switch priority"), the reviewer agreed with the arithmetic, and ruled the mirror first.

**Decision.** The mirror's position writes are batched. `native_moved` appends the move to three
preallocated parallel arrays, and one native call - `NativeTargetQuery::update_positions` - writes them
all at each *flush point*: before every query, and once at the end of the step. The C++ side keeps its
guard and its write in `update_position` and calls it per entry, so the batched and per-call paths cannot
disagree about either; the batch is a sanctioned D-095 mirror call site, not an alternate writer, and the
"three position-write sites" invariant is untouched.

**Why flush-before-query rather than once a tick.** The cell index is a snapshot while the exact test
reads live positions, so a search made part-way through a tick must see every move made before it.
Flushing at the flush points makes the writes in flight *exactly* the writes the per-call path has not
applied yet, in the same order - identical by construction rather than close - and it is what keeps the
comparison modes (`COMPARE`, `COMPARE_FULL`) usable as the oracle.

**Measured** (paired in one build, `PB_NATIVE_BATCH=off` restoring the per-call path, 20,000 soldiers,
one seed, `NATIVE_FULL` in both runs): the soldiers phase 153.703 ms against 156.864 ms and the whole tick
350.570 ms against 352.953 ms - the phase fell **3.16 ms** and the tick fell **2.38 ms**, about seven
tenths of one per cent of the tick. An auditor caught the first version of this entry calling 3.2 ms "a
tick" and dividing a phase saving by a tick total; the two numbers are quoted separately here because they
are two different claims.

**A price that was right about the order and wrong about the size - three times in one night.** The
probe's isolated price for one mirror call was 0.998 us, which predicts about twenty milliseconds for
twenty thousand movers; this pair says the marginal call in a real tick is nearer a sixth of a
microsecond, because a tight loop exposes a latency that a loop with other work in it hides. The same gap
appeared in both directions earlier tonight: the press-forward cache was predicted at 16-18 ms and
measured 10.7, and the terrain collapse was predicted at 10-16 and measured 21.8. The lesson is not that
probes lie - it is that an isolated price can *rank* candidates and cannot *size* them, so a slice is
chosen on its price and accepted on its paired run.

**A note on the price probe's row.** With batching on - which is the shipped default - the probe's
`native_moved()` row now prices the append rather than the crossing, which is why it reads lower than the
0.998 us quoted above. The switch is what tells the two apart: `PB_NATIVE_BATCH=off` prices the crossing.

**Proved, not asserted.** `tests/test_native_query.gd` drives one 1,200-unit battle twice - the switch
off for one run - and compares every soldier's carried target, liveness, health and place on every tick:
identical, with the batched run's flush and write counts checked and the reference's flushes asserted to
be zero. The suite's existing compare-mode tests, which answer every automatic search twice and compare
against the GDScript oracle, now run *under* the batched default - which is the mirror's contents being
compared after every query rather than assumed equal.

**Two limits an auditor put on the record, kept rather than argued away.** The equivalence trail compares
positions to four decimals and once per tick, so it cannot see a difference below a ten-thousandth of a
unit, or one that appears and disappears inside a single tick; what it does see is every targeting
decision, which is where a stale mirror would surface. And "the restored files are byte-identical to the
prior working tree" is not provable from repository history - git never held a blob for them - so the
claim that stands is the one that can be checked: the committed tree parses and runs, verified by importing
an export of it in a clean directory.

**The snapshot, recorded as bounded and deferred.** Bounded at ~15 ms, deferred in favour of this slice
on the reviewer's arithmetic. If it is ever taken, it should be taken as a measured experiment rather
than on its arithmetic: the in-situ discount that made this batch 3.2 ms instead of 20 very likely
applies to the snapshot's estimate too.


## D-119 - the GPU battle remembers its opponents, and the tick advances by the tick

**Context.** The CPU reference's target acquisition - keep an opponent while it is alive and
relevant, look again on a staggered tick cadence, replace an in-reach loss at once, release a dead
or out-of-relevance one (D-080..D-083) - was item 3's gap in `docs/CPU_REFERENCE_FEATURE_MATRIX.md`:
the GPU prototype struck every enemy neighbour in reach each tick and remembered nobody. Phase 4.3
slice 1 ports the acquisition rules only; the damage model remains slice 2.

**Decision.** The GPU shader carries a target buffer, one `ivec4` a soldier: the remembered
opponent's agent id and the simulation tick its next look is due. Mode 2 validates that opponent
(alive, hostile, within reach or the retention radius), keeps it and strikes it, or releases it and
looks on the soldier's own cadence (`agent index modulo the interval`, the reference's phase rule).
A loss taken inside the soldier's own reach is brought forward off the cadence; one taken further
away waits its turn. The shipped cadence is the reference's four ticks and the retention radius its
32 units. The previous behaviour - every enemy in reach struck, no memory - stays in the same shader
behind a parameter and is selected with `PB_TGT_MODE=legacy`, so a benchmark is a paired run of one
build rather than a comparison against an old log.

**Why the tick counter had to move into the tick.** The schedule reads the simulation tick, and the
tick used to advance once per *frame*. A frame that ran several ticks then gave every one of them
the same tick number, so the same battle came out differently at different frame rates: the
determinism gate caught it at tick 300, the first scripted wipe. `_tick` now advances at the end of
`_run_tick`, once per tick, and the gate passes at 20 / 30 / 60 / 120 / uncapped frames. This is the
same class of order-dependence the separation fix removed (D-116's era): the simulation's clock must
be the simulation's, not the renderer's.

**Determinism, three ways.** The search is a minimum over the neighbourhood with ties broken by the
lower agent id, so the answer cannot depend on the order the grid binned the men in; the target
buffer is written only by the soldier that owns it, so no two threads race; and the counters are
integer atomics, order-independent like the collision proof. `pb-bench/determinism_check.sh` passes
at 1,000 and at 600 soldiers (the second run reaches contact, so acquisition and a post-contact wipe
are both compared).

**The search is local, and its bound is stated.** The GPU looks in the 3x3 neighbourhood the
separation already reads, and a second ring when the first finds nobody - about nine units. The
reference escalates a ladder to 32. The rules are the same; the reach is not. A soldier whose
opponent dies out of reach waits for a candidate to enter the local search rather than being
guaranteed a replacement within the cadence, and only an in-reach loss is guaranteed to reacquire at
once. The rule check reports the split rather than hiding it: 15 of 27 bereaved soldiers found a new
opponent within a cadence, the rest had none local.

**Measured, paired in one build** at 6,000 and 20,000 soldiers, same seed, the ladder's own settings:
the tick 0.055 ms against 0.054 and 0.071 against 0.070; the repack 9.027 against 8.999 and 29.954
against 30.076; throughput 95.1 against 95.5 and 30.8 against 30.8 ticks/s. Acquisition is free at
the instrument's resolution, and the 6,000 run still does the work: 2,010 acquisitions, 545,159
retained soldier-ticks, 101,376 scheduled re-searches, for about 0.24 looks per soldier-tick - one
look every four ticks, which is the cadence doing its job.

**What is not claimed.** The damage model is not ported (still a flat 0.25 hp a strike), and the
acquisition is not identical to the reference in every internal detail: the radius and the search
are the bounded difference above, and the GPU has no separate focus fallback or retaliation path
(those are later slices). What is equivalent is the observable rule set the reference's
`test_target_acquisition.gd` pins: keep, staggered cadence, immediate in-reach replacement, release,
and no thrash between similar enemies.


## D-120 - roads are a living network: a tier per link, worn by traffic, aged by years

**Context.** The owner, on what roads should become: "real roads that also get built over time,
because later we will have settlements being built by the ai" - and, on the two forks put to him: a
settlement founded later spawns "a dirt road... but will only give a very small bonus"; an unused link
can fall "roadless, it takes years though, so I doubt it will ever happen". Before this the network
was frozen at world-gen: one spanning tree, priced once, a static list in the save, and nothing could
add, move or age a link.

**Decision.** A link's tier lives in the same `kind` field every reader already touches -
`none | dirt | track | road`, ordered by `roads.tiers` in the config, each with its own speed bonus
(dirt 1.05, track 1.2, road 1.4), so the grid, the map, the eta and the pace all read one number.
`RoadNetwork` owns the ledger: every link carries `traffic` (world units walked on it) and
`used_hours` (total game hours at last use). A settlement founded later calls `connect_settlement`,
which links it to its nearest neighbour as a dirt road. Traffic arrives through the travel service's
own steps (`charge_move`, throttled to `traffic_scan_hours` windows, attributed to the link nearest
the walked stretch); `review` runs the slow clock - every `review_hours` of game time, a link with
`upgrade_traffic[<tier>]` met rises a tier with the spill kept, and a link idle for
`decay_days_per_tier` game days (3650 by default - the owner's "years") falls one tier, to the
`none` floor, from which traffic can wear it back in. A tier change marks the ground dirty and the map
re-prices the whole 64x64 grid in place (~140 ms - an event, not a frame cost). Old saves load as
roads: an unknown kind reads as `road`, and a missing `used_hours` stamps *now*, not year zero, or the
whole network would decay the moment it loaded.

**Why traffic counts world units walked.** Distance is physical and needs no new unit: one crossing of
a ~600-unit link is ~600 traffic against dirt's 800 to rise. Every number lives in
`data/config/game_config.json` under `roads`; nothing is hardcoded.

**Where the tiers show.** The map draws the ladder - road full width with a highlight, track narrower
and plainer, dirt a thin line, `none` not at all - and the priced grid stamps each link's cells at its
own tier's bonus (`none` stamps nothing). The world opens with its elder towns already at `road`; the
dynamics are for what gets built after.

**Proved, not asserted.** `tests/test_roads.gd` (68 assertions): the ladder and every bonus ordering,
normalising (including the stamp-now reading), a founded settlement's dirt link to its nearest
neighbour, upgrades on threshold with the spill kept and no climb without traffic, the full decay
ladder over 3650-day spans down to the roadless floor, the roadless re-stamp of the grid and revival
by traffic, per-tier grid prices asserted as exact cell costs, the walking factor agreeing with the
price it was built from, a walked settlement route wearing its link, and the whole ledger surviving a
save.


## D-121 - the eta, the pace and the grid are one number now

**Context.** Three speeds disagreed on one journey: the grid priced a link at its bonus, `step()`
walked at a flat base pace that ignored the ground entirely, and `hours_to_reach` quoted the
straight-line distance divided by the factor at the party's *current* spot - so standing on a road
over-promised the whole journey by up to forty per cent. The owner, asked what he wanted from roads:
"all of this" - speed feel, honest etas, the network shape - and the fix is one rule rather than
three: the ground's own number.

**Decision.** `TravelCosts.factor_at(point)` recovers the exact factor a cell was priced from
(`1 / (cost * base)`); `TravelService.ground_factor()` reads that grid answer for the party's
position, and both the route walk's budget and the direct walk apply it - the pace on a road is the
road's own price and not a second opinion. `hours_to_reach` prices the line in 32-unit samples rather
than at one end, so a marsh between costs more and a road underfoot pays where it runs. Without a grid
(suites and fixtures that build a travel service alone), the previous field-and-route reading stands
as the fallback.

**The suite rebuilt to the new substance.** `test_world_map` had gone red holding three old truths: an
eta with no ground factor, a one-hour step not capped at `max_step_units`, and a clock hardcoding two
real seconds to the game hour against a config that says ten. The tests now assert the new contract in
config terms - the eta bounded between best-road and worst-water, a step covering its own hours at
`min(pace x factor x hours, cap)` and never outrunning the cap however much time it is handed, and the
clock read from `time.seconds_per_game_hour` and `time.speed_multipliers` rather than literals - so a
retune of the config retunes the suite with it. 116 assertions, 0 failures.


## D-122 - the walk follows the drawn road, because the blocks were never the road

**Context.** Step 8's first cut made the pace and the price read the grid's blocks: a 64-unit cell
the road curve passes through is priced at the road's speed, so anything inside that block walks at
1.4x. The drawing, though, is a thin curve, and the route the pathfinder returns is cell centres -
so the walk split the difference. The owner, watching his pawn, put it exactly right: "if the game
thinks I'm on the road, and I see that I'm off the road, and I see my pawn moving in a straight
line, I think the game thinks that block is road. is that how this is wired up?" It was. The
on/off-road travel log, added for exactly this question, measured the walk wandering up to 31 units
off the drawn line while still reading "100% on roads" by the wear corridor.

**Decision.** A route's road stretches are spliced onto the link's own curve - the same 48 points
the map draws and the grid stamps - before the party walks them. `build_route` samples the A*
answer every 16 units, groups the samples by the link they are nearest (inside the corridor the
wear scan uses, so "snapped" and "credited with wear" are one condition), and replaces each run
with the curve points between its entry and exit projections, walked in the route's own order.
Off-road stretches keep the pathfinder's line, corner for corner; both endpoints are kept exactly;
the same order builds the same route twice (asserted). Everything downstream is unchanged: the grid
still prices blocks, the pace still reads the block's factor, wear and the eta read positions - the
walk simply *is* the line now, which is the only thing the eye ever saw.

**Measured.** Debug-1 pass, seed 5150: before, three legs logged worst gaps of 15 / 31 / 14 units
off a line; after, the trace reads "0 u off its line" through the legs. The suite section "the walk
follows the drawn line" walks a real journey and asserts the worst gap stays under a dozen units,
the endpoints land exactly, and the route is deterministic.

**The question built its own answer.** The owner asked for on/off-road logging before any fix -
"that way you can see whats actually happening" - and the logging is what proved the blocks
disagree with the line, to the unit. Instrument before arguing about a picture.


## D-123 - a march to open ground is a real march, and the pace is on the panel

**Context.** Two things the owner found within a minute of playing. First: "I can't click on random
spots, only locations (settlements)". The right click was wired and `set_destination_point` worked -
in a *fresh* campaign. But a point order never cleared the route a previous settlement order had
built, and once the party had arrived at the end of that route, the next march "arrived" on its
first step without moving: the stale geometry finished under the party's feet. Second: "I don't see
a speed increase on the roads" - the bonus was working (his own session's log: 273 units walked in
1.35 game hours is 202 u/h against a 150 u/h base), but nothing on screen put a number on it.

**Decision.** `set_destination_point()` and `clear_destination()` drop the route with the order; the
march is a straight walk from where the party actually stands. The debug panel's pace line now
shows the pace a player actually gets - `speed x ground factor`, so a road reads
"210 u/h (ground x1.40)" and open field "150 u/h (ground x1.00)" - because a bonus nobody can see
is a bonus nobody believes. Road strength itself is untouched; it is a config number
(`roads.speed_bonus`) if the owner wants a stronger feel.

**Proved by reproduction, not by reading.** `test_world_map`'s march section now walks a full road
journey, then marches to open ground, and asserts the party moves, does not insta-arrive, and heads
toward the clicked spot. With the fix stashed the three asserts fail with exactly the owner's
symptom (distance travelled 0.0); with it, 116/0.


## D-124 - the pace and the eta read the drawn road; the grid only prices

**Context.** D-122 made the *walk* follow the drawn curve, but the speed it walked at still came
from the priced grid's 64-unit blocks. So x1.4 switched on and off up to tens of units away from
the drawn road's edges - the owner, after watching: "still don't see the speed increase when on
roads". The bonus was in effect (his own session logs: 197-208 u/h road legs against a 150 u/h
base), but a speed change you cannot attach to anything you can see is a speed change you cannot
see. And the block was the *third* yardstick for one question: the wear scan, the on/off-road log
and the snap all read the drawn corridor; only the pace and the eta read blocks.

**Decision.** One yardstick for "how fast am I walking here": the drawn roads answer first.
`RoadNetwork.bonus_at(point)` returns the best tier bonus among the links whose corridor (the
`traffic_radius` the wear scan and the snap already use) holds the point, or 0 on open ground;
`TravelService.ground_factor()` and `factor_at_point()` read it, and fall back to the raw field
when no road is near. The priced grid is unchanged and keeps the one job it is good at: pricing the
route for the pathfinder (`build_route`), where 64-unit resolution is fine because the router only
needs to know that roads are cheaper.

**Consequences.** The pace changes exactly at a road's visible edge (the ~48 u corridor the snap and
the wear scan already agreed on), a march crossing a road gets a speed blip inside that road's own
footprint, and pace, wear, the on/off log and the eta all speak one language; only the router speaks
block. Because the grid's road stamps no longer leak into the walk, a point inside a road-painted
block but beyond the corridor walks at field speed - the exact complaint, closed.

**Proved.** A new `test_roads` section: on the line the road answers, inside the corridor it still
does, past it the field does; and a search finds a point the grid paints as road while the line is
beyond its corridor, asserting the pace no longer inherits the block's speed (74 assertions, 0
failures). Live, a dev-1 pass walked its road legs at 194 u/h against the 150 base and its
half-road legs at 137-166, worst 0-11 u off-line, no script errors: the walk is the line, and the
speed is the line's. (That pass also had a human at the controls - point marches appeared, which
only input orders, and the time-speed changed with them - so its wall-clock figures are skewed; the
game-hour speeds above are the ones that matter.)


## D-125 - the ladder spaced for the eye: road x2.0

**Context.** D-124 made the walk's speed follow the drawn road exactly, and the log proved the
mechanism to the unit - but the owner, playing: "I can't really see the difference, can we make the
speed changes a bit more exaggerated?" At x1.4 a road beat open ground by a couple of pixels a
second at the map's own zoom; a correct number is not a felt one.

**Decision.** Space the ladder for the eye: `none` 1.0, `dirt` 1.1 (kept inside the owner's own
"very small bonus" band), `track` 1.5, `road` **2.0**. On a road the party now walks at twice its
open-ground pace - the marker visibly doubles - and against marsh (x0.55) a road is 3.6x. Because
pace, eta and the routing prices all read the one config number, nothing else needed an edit; the
suite's eta bound now reads the value from the config rather than a literal, so a future retune
does not break it. The dirt bound test (`dirt <= 1.1`) is the owner's "very small bonus" spec doing
its job - it caught 1.15 and sent the number back to the band.

**Not changed.** Wear, upgrade thresholds, decay and the 48 u corridor are untouched - a pace
decision, not a network decision. Too arcade? `roads.speed_bonus.road` in
`data/config/game_config.json`: 1.8 and 1.6 are the natural steps back.


## D-126 - the pace counts the road you can see (10 u), not the wear shoulder (48)

**Context.** D-125 made the difference felt, and the owner, watching it with real contrast for the
first time: "the speed changes dont come in until I leave that block, that's the issue, and why I
never saw the changes." The pace (and the on/off log) read `roads.traffic_radius` - 48 units, the
corridor chosen so that walking *near* a road wears it. That is six to ten times the drawn line's
width, so the boot landed up to a corridor's width past the road's visible edge, and the flip could
coincide with what looks like a block boundary. At x1.4 the misplacement vanished into the jitter;
x2.0 made it a complaint - which is the whole argument for spacing things extreme enough to see.

**Decision.** Two radii, each answering its own question, both in the config:
- `roads.pace_radius` (10 u) - "are the party's feet on the road?" - the pace (`bonus_at`), the
  on/off log and the journey ledger's share. The flip now lands within the party marker's own width
  of the line in both directions, and a crossing march blips for ~20 u instead of ~100.
- `roads.traffic_radius` (48 u) - "did this walking wear this road?" - the wear credit and the
  snap's pull onto the curve, both unchanged: a walk on the road's shoulder still wears it, and the
  pathfinder's chords are still pulled onto the drawn line so the marker rides it.
- The eta deliberately keeps the wide corridor: it samples a straight line, which cannot see the
  curve underfoot, and the wide reading is what kept quoted hours matching arrived hours (1.5->1.6,
  1.7->1.7, 2.6->2.7 in the owner's own session).

**Proved.** test_roads: on the line the road answers; at six units off it still does; at forty the
field does; the pace radius is asserted narrower than the wear shoulder; the block-leak search
still passes - 75 assertions, 0 failures. All suites green (test_world_map 116/0,
test_campaign_flow 41/0, test_core_services 83/0).


## D-127 - roads answer to the water, and look like ground

**Context.** The owner, with the pace finally right: "can we make the roads look more like terrain?
also I want to add a few rules to them, 1st one to add and test, don't let them run over water, but
we could do bridges over water." Both land in one place, because the curve already was the single
source of truth - `RoadPath.between()` shapes what the map draws, what the grid stamps, what the
party walks and what the snap splices onto - and terrain was the one input it never read.

**The water rule.** `between()` now takes the terrain (and the water height and a bridge limit).
The canonical bend is tried first, then its mirror and wider bows, and the first shape that is dry -
or whose only water is a stay within `roads.bridge_max_span` (64 u) - wins. Such a stay is recorded
as a *bridge span*: `RoadPath.water_spans()` gives the [start, end] index pairs that the map draws
as timber and the walk crosses at road speed, because the grid stamps the span as road ground
(which is exactly what a bridge is for). A lake wider than the limit is bent around; when no bow can
avoid it, the least-wet shape wins and can never be wetter than the plain bend. Deterministic like
everything else about the curve: same campaign, same water, same road. All four consumers now pass
the same shared `WorldChunks` instance - memoised per seed as of this change, because four seams
were each re-generating the same chunks - so the drawn line, the stamped cells and the walked line
cannot disagree about where the water is.

**The look.** The roads stopped being UI strokes drawn over the map: the hard dark casing and the
bright highlight are gone, replaced by a soft trampled margin in low-alpha earth, an earth-toned
core pulled from the ground's own flat-shader palette (worn earth, dry grass, sand), and - on a
proper road - a worn centre strip; bridges draw as dark planked spans with a post at each bank. The
visual pass was judged from desktop screenshots and crops rather than code reading: two rounds, the
second one darker and earthier after the first read as "pale flat line, pasted on".

**Proved.** `test_roads` grew two sections: a river (a stand-in band terrain) is crossed and only
crossed inside recorded spans, no wider than the limit, the same road twice; a wide lake is never
wetter than the bare bend or the straight crossing; dry land draws exactly the historic bend; and a
network given a stand-in terrain shapes its link as a bridge and walks it at the link's own speed.
86 assertions, 0 failures. Loading cost of the rule: costs 99 -> 315 ms and first-run loading
~1.8 -> 2.0 s - the price of every link being shaped against the field; worth watching, not yet
worth optimising.


## D-128 - the country between the settlements

**Context.** The owner, playing the map after the roads work: "the space between settlements are way
too close still." The world could fill with 36 sites because a village's spacing floor was 240 u - a
quarter of a grid block between neighbours - so the survey happily packed the map until nearly
every chunk's best spot was taken.

**Decision.** The ladder lifted (and the count asked for lowered, 36 -> 20): village 240 -> 460,
fort 300 -> 500, town 460 -> 600, castle 620 -> 760 - the same owner rule as ever (a castle keeps a
county, a fort may sit close to the town it serves), just spaced for a map you can breathe in. The
survey's candidate pool is finite (~36 qualifying sites per seed), so the spacing floor decides the
final count: at 460 the world places 17-20 settlements, closest pair ~462 u, average nearest
neighbour ~503 u, against ~341 before. A hop between neighbours is now two to three game hours where
it was one - which is the point.

**Instrument.** The world build now logs what the eye was asking: "country: closest pair N u apart,
average nearest neighbour M u" - the numbers this decision was tuned against, visible in every run.

**Measured.** Seed 5150: 17 sites, closest 462, average 503. Seed 1234: 20 sites, closest 466,
average 505. Tests: `test_world_sites`' floor assertion follows the constant (closest pair 465.9 u
measured against a 460 floor); test_roads 86/0, test_world_map 116/0, test_campaign_flow 41/0.


## D-129 - the stalls, not the frame rate: the map stops freezing on tier changes and town visits

**Context.** The owner asked for frame-rate work "without affecting quality visuals". Measuring first
(a new `--framelog` on the FPS overlay: per-second fps, mean/worst frame time and process time, and
any frame over 25 ms named the moment it happens) said the steady state was never the problem:
352-360 fps at 2.79 ms mean against the 360 Hz vsync cap, worst frames ~3 ms. What the log did show
was stalls: a **219 ms grid rebuild** on every map entry and on load, a fifth to a third of a second
frozen on every road tier change, and the ground builder's ~70 ms slices during transitions.

**Decision - caches and re-stamps, no pixel touched.**
- A road changing tier is **re-stamped in place** (`TravelCosts.apply_tier`): its cells are
  recomputed as bare terrain and every link stamps them again, so a cell shared with another road
  keeps that road's price. The grid it produces is asserted cell-for-cell identical to a full
  rebuild across all 4,096 cells (`test_roads`). Where every upgrade froze the map, this costs one
  link's footprint.
- The priced grid **and** the road network ride on the campaign (`CampaignState.travel_costs` /
  `road_network`; runtime only, never saved): both are deterministic from the seed and the links, so
  a visit to a town no longer rebuilds them on return. Measured on a scripted entry-and-return: the
  cost phase went **219 ms -> 0 ms**; the network's terrain-shaped curves (the phase's other 52 ms)
  are cached in the same breath.
- Seeing this is part of the fix: `--framelog` turns the on-screen FPS label into a greppable
  record and names every hitch as it happens.

**Left alone, deliberately.** Steady-state rendering (already at the cap), the loading screen's own
work (behind the bar, by design), and the per-frame redraw of the map view - the numbers do not
justify splitting it today. The battle renderer has its own bench (`render_bench.gd`) for its own
milestone.


## D-130 - the eta quotes at the route scale, and the causeway stays on the map

**Context.** Two findings from a play session the owner ran himself (seed 2108518669). First: the
opening road leg was QUOTED at 2.4 game hours and WALKED in 1.64 - the eta was pricing a road
journey as open field in places, because D-126's text promised the eta kept the wide corridor while
the code shipped it reading the pace's own drawn width (10 u), so its straight-line samples fell
outside the curvy road. Second: "roads: 3 of 19 links cross water by bridge (widest 396 u)" - a
396-unit lake crossing carrying a timber span, because no bow the shaper tries can dodge that much
water on a link that long.

**Decision.** `RoadNetwork.bonus_at(point, radius)` takes the width as a parameter: the pace asks at
`pace_radius` (10 u, unchanged), the eta's `factor_at_point` asks at `road_radius` (48 u). The two
yardsticks are asserted at once in the suite, forty units off the line - the walk reads the field
there, the eta still reads the road. Measured on the same seed after the fix: the Crowwood leg
quotes **1.6 h** against a 1.64 h walk, where the bug quoted 2.4.

**The causeway.** The bow list grew (2.2x candidates as well as their mirrors) - it did not reduce
the 396-unit span on this seed, and it will not: a lake too central for the bow reach is beyond
what a bent bow can do. That crossing is drawn and walked as a real bridge, and the honest fix for
the general case is road paths that FIND their way around water rather than bending - 
pathfinding-shaped roads, a design step of its own, noted rather than smuggled in here.

**Lesson kept.** The eta bug was invisible to every suite - the numbers it prints are self-consistent
- and took a real play log comparing the QUOTE against the VERDICT to catch. When a play log lands,
read it like a test report.


## D-131 - the logs check the game's own answers

**Context.** D-130's eta bug was only visible by hand-comparing a quote against a verdict. Three
additions make the log grade the game by itself, so that comparison happens every journey:

- **The arrival line carries the grade**: the order's quote is kept, and the arrival prints
  "quoted ~1.6 h, walked 1.64 h (+2%)". Measured live on the first leg after shipping: +2%.
- **Hitches are always on**: any frame of 50 ms or more goes to the log in every session, flag or
  no flag, capped to one line a second so a rough load cannot bury the log it feeds. The owner's
  build never passes flags; his sessions are the performance record.
- **One device line at boot** (GPU, driver, window, vsync and refresh, CPU): every performance
  conversation starts with facts instead of "should be fine". The `DeviceReport` helper already
  existed for the benches; it now has a one-line form for the session log.


## D-132 - the ground is cached, and the loading screen only covers real work

**Context.** Every return from a settlement showed the map in "its first state, just a grid" for
about 580 ms before the terrain appeared. With the world and its grid already on the campaign
(D-129), `WorldBuilder.needs_build()` was false on re-entry - and the loading screen was only
created inside that branch, so nothing covered the ground's build at all. The map drew its
placeholder fill and grid while the ground layer ran behind it. The owner's report and the capture
that matched it (frame 4 of `pb-bench/town_frames_before`, confirmed by eye): bare fill, no terrain.

**Decision.** Two changes, in the order the numbers asked for:

1. **The flat ground's field image is cached on the campaign** (`CampaignState.ground_field`), the
   same trick as the priced grid (D-129): it is a pure function of the seed and the land rectangle,
   about 66 KB, runtime-only. Measured on the town round-trip: ground build **583 ms -> 8 ms**.
2. **The loading screen is only created when there is real work behind it** - a fresh world, or the
   first entry of the session (when the ground cache is still empty). With a cache hit there is no
   bare window to cover, and a screen that flashed for 8 ms on every town exit would be noise.

The entry log now says which kind of entry it was: "ground done at 8 ms (cached)" against "ground
done at 587 ms" for a build. Verified by the same captures (`town_frames_after`): no frame between
the settlement and the loaded map shows the placeholder state any more, and the first map frame
carries terrain, roads and settlements.


## D-133 - the interface speaks one language: pixel chrome, serif body, prose on hover

**Context.** The menus were dressed in `PixelStyle` - nine-patch frames, Silkscreen, the accent
spent on hover - while every in-game screen was still flat grey panels in the engine's default
font, with text everywhere: recruit cards carried a pitch paragraph, a prose stat sentence and a
stock note; the party column clipped its own header ("Your Party (1 / 24 active") and ran trait and
history lines off the panel edge. The owner, shown three directions mocked at real scale, picked C:
"c - descriptions need to not be everywhere, you kind of throw text everywhere but can be helpful
just maybe a hover tool tip maybe?".

**Decision.**

- **Pixel chrome everywhere.** The menus' palette (BODY/LIGHT/DARK/OUTLINE, the accent spent on
  hover) and `PixelStyle` furniture dress the settlement screen now; the map HUD and the dialogs
  follow.
- **Two faces, two jobs.** Silkscreen for headers, buttons, prices and numeric values; EB Garamond
  (OFL, bundled in `assets/fonts/`) for names, labels and anything read as a sentence.
- **Prose lives on hover.** Unit descriptions, trait text, the town's own blurb and a soldier's
  quick facts are tooltips; cards carry name, price, stock, stat chips and buttons. One theme on a
  screen's root (`PixelStyle.tooltip_theme`) dresses every popover, so a tooltip reads as part of
  the game. The detail pane is the one place a full record is allowed - click, not hover.
- **Glyph rule.** Silkscreen carries basic ASCII only; separators in the pixel face are `|` and
  `/`, because a missing `·` is a tofu box, not a typo.

**Measured.** The rebuilt screen (seed 5150, Blackburrow, three recruits): no tofu, no clipping,
chips readable at 1440p, the selected soldier's record complete. Portrait slots show initials until
the art factory bakes heads.

**Follow-through.** The pass carried to every remaining screen: `world_hud` (status grid, speed bar,
actions, hint), `settlement_panel` (the town inspector, its blurb on hover), `encounter_dialog`,
`battle_results_screen`, and `loading_screen` (pixel title and status, the bar in a nine-patch
frame, `|` in place of a middle dot the pixel face may not carry), plus a much darker
disabled-button state - the old one read as enabled at 11 px. Two screens are read by suites, so
their restyle is deliberately chrome-only: `displayed_text()` collects every Label and Button
string from the results screen, and the HUD's party wording is asserted through `stat_text()`. Both
keep their exact wording. `test_party_semantics` stays at its known-red 5 failures - stash-proved
pre-existing, the HUD shows "-" because the suite's world never finishes wiring under the revert
fallout, not because of the dressing.

**The right gutter.** A `ScrollContainer` reserves the scrollbar's width, so every right-aligned
value in a scrolled pane ended flush against it - the owner, on the soldier record: "the text on
the right needs to shift more to the left". The content of all three scrolled panes now sits in a
`MarginContainer` with a 16 px right margin, which gives the values one consistent gutter, shared
between the party rows and the record below them.


## D-134 - the log rotates, and a jump is no longer silent

**Context.** The owner asked for his own play session to be read, and the session was gone:
`DebugLogger` opened `session.log` with WRITE, so every run truncated the last one, and a suite run
beside his live game destroyed the play he was asking about - the file was NUL-padded where two
writers disagreed about the end of it. The same session carried one reported symptom - "the
positioning while moving through the campaign looked weird at one point" - and no log line existed
that could have caught it.

**Decision.** Two small repairs.

- **Rotation instead of truncation.** At session start `session.log` is renamed to
  `session.prev.log` (exactly one previous session kept). "What did the last run do" is always
  answerable, and the current run is still a clean file.
- **A one-step jump is a warn.** A step cannot move the marker further than `max_step_units`, and
  an arrival snaps at most `arrival_radius`, so anything beyond `1.75 x max_step_units` in a single
  step is not travel - it is a teleport. It writes `travel: position jumped N u in one step (x,y ->
  x,y)`. The reported class of weirdness is measured next time instead of remembered.

**Habit, not just code.** Before starting any run or suite while the owner's session matters, copy
`session.log` aside first: rotation protects one slot, it does not protect an investigation.

**Follow-up - the debug furniture moved right and off.** The faction overlay and the debug panel
used to sit top-left with the frame rate, all three stacked over the HUD's own status panel ("this
ui looks like its overlapping"). The owner: "move the fps one and all that to the right of the
screen and toggles on/off with f1 (should initially be toggled off)". The overlay anchors to the
top-right (12 px in, growing leftward) and the debug panel hangs under it at y 58; F1 shows both as
one thing, and both start hidden. Frame counting and the hitch warnings are independent of
visibility - verified: a hidden run still logs `[WARN][Perf] hitch: 261.2 ms` through the load.

Two repairs on top of that: the debug panel's right-anchor used explicit offsets after it hung off
the screen edge on the first attempt (only a sliver visible), and `--debug-panel` (DevFlags) opens
with the debug panel + overlay showing, because a scripted run and a screenshot cannot press F1.


## D-135 - the pricing grid goes to 32 units a cell, and squares stay while hex is considered

**Context.** The owner, watching the F1 overlay: "I noticed the blocks when in debug mode, can we
make the grid blocks smaller?" - and then, with the smaller blocks on screen: "question would a hex
system be better?"

**Decision - the cell size.** `TravelCosts.CELL` 64 -> 32 (128x128 cells, 16,384). The sampling is
four times the work: measured **593 ms** once on a fresh campaign, against the 136-220 ms at 64 -
paid once and then cached on the campaign (D-129), so re-entry still costs 0 ms. Every route now
hugs a drawn road twice as tightly, and the debug overlay's blocks are four times finer (~15-20
squares between towns instead of 4-6). The doc header keeps the measurement history: 64 was chosen
at 136 ms against 8.5 s at the field's own 8 units.

**Decision - square versus hex: squares, and why.** Hex's headline benefit - no diagonal shortcut -
does not exist here: nothing moves on the grid. The party walks continuous world units along drawn
curves, battles are continuous fields, and the grid only prices routes, with diagonals already
priced at sqrt(2). Hex becomes the better answer only when movement becomes tile-stepped or the
campaign grows ring/radius rules (zones of control, facing, tiles-of-reach); until then a hex
rebuild of the pricing layer, its stamping, its re-stamp equivalence and the debug drawing is a
refactor with zero gameplay difference. Recorded so the question is answered once rather than
re-litigated.

**The fixture that had to change.** `test_roads`' "the grid paints road beyond the drawn corridor"
search was window-sized for 64 u blocks and no longer found a probe by luck; it now constructs the
probe from the two radii (the centre of the cell the line passes through: inside the 48 u stamp
corridor, outside the 10 u pace corridor), and its follow-on assert moved from the eta to the pace
- the eta reads the route scale there deliberately (D-130). 90 assertions, green.


## D-136 - the settlement detail card, on hover

**Context.** The owner: "lets add some stuff to the settlements, this is going to be the settlements
details, which this info needs to pop up via a hover over. building listings, trade goods,
population, (scouted info), noble families and their power % in that settlement. give me more
ideas." He approved the v1 cut with one amendment: "the rumors will come from the taverns later" -
so no rumour line yet, and taverns are noted as its future home. Two decisions taken as proposed:
the card appears after a 0.25 s rest, near the cursor; houses run one to three per settlement.

**Decision.** The detail is generated, never authored: `SettlementDetails.fill()` is a pure function
of the campaign seed and the settlement's id, so a run is reproducible, an old save regenerates the
same town, and nothing of it has to survive serialisation on its own. Fields added to `Settlement`:
`buildings` (3-7 chips, each with a one-line note in its tooltip), `produces`/`wants` (2-3 goods
each way, never the same word), `families` (the owning house always first and largest, powers sum
to 100), `wealth` (poor/modest/wealthy by population) and `garrison` (a per-kind factor of
population, shown with a `~`). `last_visited_day` is stamped wherever `visited` is set, so a stale
card reads as stale.

**The card.** `SettlementHoverCard` follows the cursor (clamped to the screen), appears after a
0.25 s rest so sweeping the map never flickers it, and hides the moment the cursor leaves. It never
takes the mouse - every node inside it ignores the cursor - so resting on a settlement can never eat
the click that orders the march. Unvisited places show the unscouted form: name, kind and the
travel line only. Clicking still opens the action panel with Travel and Enter; the map entry
backfills old saves idempotently, and `--hover-card[=<id>]` boots with the card showing for
screenshots and scripted runs.

**Verified.** Seed 5150, Blackburrow: HOUSES House Caldreth 70% (accent bar) / House Dunmore 30%
(quiet bar), buildings GRANARY / MILL / TAVERN, Produces hides, turnips, wool, Wants salt, iron,
Garrison ~9 spears, Wealth poor, visited stamp on the footnote. No clipping, no missing glyphs. New
suite `test_settlement_details` (42 assertions): determinism per seed and id, powers summing to 100
with the owner leading, buildings 3-7 unique and named, trade never overlapping, wealth/garrison
following population and kind, old-save backfill and fill idempotence, round-trip through a save.

**The trap worth remembering.** Assigning an untyped `Array` to a typed `Array[String]` property is
a runtime error in GDScript, and the error aborts the whole function - `fill()` died mid-way, which
showed up as unrelated-looking failures three fields later (empty wealth, zero garrison). Type the
generator's returns to match the model's fields.

**Follow-up - trade comes from the buildings.** The owner's rule: "when generating what the
settlement provides, it must have the same buildings that produce that item." Trade is no longer
rolled separately: every building names the goods it can provide, produces are drawn from that
union, wants are the kind's list minus everything the town can make, and a repair pass swaps
non-producing picks for producers until the town can make at least three goods. `DETAILS_VERSION` 2
regenerates saves written under the old rolls on the next map entry. The same review caught a tavern
selling ale it did not brew: Brewhouse now brews, Tavern keeps its identity as where rumours wait.


## D-137 - Settings, in the main menu and the Esc menu

**Context.** The owner: "also add a settings in the main menu, and esc menu."

**Decision.** Display only, deliberately - window mode (Windowed / Fullscreen, where Fullscreen is
Godot's borderless mode), VSync, and a frame cap (Uncapped / 60 / 120 / 144 / 240 / 360). Those are
the knobs the game actually has; there is no sound system yet, and a volume slider attached to
nothing is a lie.

- `GameSettings` (autoload) owns the option tables, `user://settings.cfg` and `apply()`. Applied at
  startup only when the file exists, so a fresh install keeps the project's defaults and a dev run's
  command-line flags stay strongest. Each row is a cycle button: the change applies and saves the
  moment it is clicked, so there is no OK button to forget.
- `SettingsPanel` is shared by both menus. It handles Esc in `_input` - which runs before any
  `_unhandled_input` - so closing the panel from the pause menu can never close the pause menu with
  it. The panel sits slightly right of centre so it never covers the menu column's own words.
- Tests write to their own `user://settings_test.cfg` and never call `apply()`: a suite must not
  resize the window of the machine it runs on. `test_settings` covers table alignment, wrapping, and
  the save/load round trip. `--settings-panel` opens the panel at boot for screenshots.

**Verified.** Main menu: SETTINGS sits between NEW CAMPAIGN and QUIT, and the panel opened showing
`FULLSCREEN >`, `ON >`, `360 >` with the footer reading "Applied: fullscreen, vsync On, cap 360."
The same panel hangs off the Esc menu above Resume's column.

