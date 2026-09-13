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

**What was measured before anything was changed.** The path was counted, not guessed at. At
twenty thousand soldiers a tick ran 2,436 looks - not the 5,000 a cadence of four would imply,
because the focus proof of D-087 skips half of them - and each look cost 219 us inside the grid
query, which the phase timers put at 86% of the whole target phase. One look made **1.77 grid
queries**: one per rung of the escalation ladder, 24% answered by the first rung, 44% answered
after widening, 32% answered by nobody at all. Per look the ladder read **260 cells** and handed
over **171 candidates** to be measured so that one of them could be kept. The second rung was
78% of the query time.

**The diagnosis the milestone started from, and the one it finished with.** The starting
assumption was that the *traversal* was the problem: that a walk which opens each cell once,
stops when no unopened cell can improve the answer, and never materialises a candidate list
would be several times cheaper. Five exact implementations of that idea were written and
measured, in a micro-benchmark built for the purpose (`scripts/dev/search_bench.gd`) and in
live battles:

Each was measured twice: once in the micro-benchmark, on the same twenty thousand queries at
the same density, and once in a live battle, by running the whole realistic sweep on that
implementation and comparing the target phase against the locked build's. The two do not agree,
and the reason is worth stating rather than averaging: the benchmark is one query at a time on
a warm index, while a battle runs two and a half thousand of them a tick against an index
rebuilt every tick, so a per-query ratio is a floor rather than the whole story.

| implementation | shape | micro-benchmark | live battle, 20K target phase |
| --- | --- | ---: | ---: |
| Chebyshev ring walk | cells opened ring by ring outward from the soldier | 2.6x | **2.64x** (1,638.1 vs 621.1 ms) |
| row walk, index order | rectangle pass with a per-row reach window | 1.9x | not run |
| row walk, nearest rows first | the same, rows and columns outward from the soldier | 1.8x - 2.1x | **2.92x** (1,749.2 vs 598.5 ms) |
| rectangle walk with a cell bound | one distance test per cell before its bucket | **2.3x** | not run |
| block-indexed walk | a coarse 4x4-cell side mask walked before the cells | 3.3x | **3.87x** (2,318.4 vs 598.5 ms) |

The two battle figures are quoted against slightly different "before" runs of the locked build -
621.1 ms and 598.5 ms - because each implementation was compared with a sweep taken beside it
rather than with one stored reference. Both are the same code on the same machine within the
same session; the spread between them is the spread of the benchmark, not of the search.

Every one of them inspects *fewer* cells and fewer candidates than the ladder - the best of them
read 122 cells and measured 45 candidates per look against the ladder's 260 and 171 - and every
one of them is slower. The isolation run says why: **one radius-32 box costs about 300 us
whichever way it is walked**, and the ladder is cheap only because its first rung answers most
looks before the second rung is reached. In an interpreter, a bound test in a loop body costs
about 0.3 us and the empty cell it skips costs about 0.12 us to open and dismiss. A walk that
prunes per cell pays more for the pruning than it saves on the skipping; pruning pays only where
it lives in the loop bounds, and the cheapest loop bounds are the ones a rectangle already has.

**Decision: the search is unchanged.** No re-implementation is shipped. The ladder's staging - a
small first rung that answers most looks, widening only for the looks that find nobody - is
already the right architecture for this cost model, and its blunt loops are the cheapest form
the language offers. The blocks-and-rings version was discarded with the block mask it needed,
because keeping the mask would have cost a write per soldier per tick in the rebuild for a path
that never runs.

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
