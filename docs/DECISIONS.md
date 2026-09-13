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

