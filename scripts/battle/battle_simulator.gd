class_name BattleSimulator
extends RefCounted
## The battle, as pure data.
##
## Combat resolution lives here rather than in the battle scene, so the whole
## fight can be run headlessly with no rendering, no frame timing and no input.
## The scene is a view over this object.
##
## [b]Scope note.[/b] Movement, targeting and order handling are implemented; the
## damage step lands with the combat milestone. The battlefield is deliberately
## built so that adding damage does not change any of the interfaces below.

enum State { DEPLOYING, RUNNING, FINISHED }

## Distance within which units shove each other apart instead of overlapping.
const SEPARATION_FACTOR := 0.9
## How close to its slot a soldier has to be before it stops shuffling. Without this
## a formed unit jitters forever around a point it can never exactly reach.
const ARRIVE_EPSILON := 0.15

var config: GameConfig = null
var rng: RandomNumberGenerator = null

var units: Array[BattleUnit] = []
var state: State = State.DEPLOYING
var elapsed: float = 0.0
## Simulation ticks completed. The only clock target scheduling is allowed to read: an
## integer tick counter that a re-run reproduces exactly, never a wall-clock reading and
## never a rendered frame. See D-080.
var tick_index: int = 0
var winner: String = ""

## Events produced by the most recent [method step] call. The view consumes them;
## nothing else should depend on their contents surviving a frame.
var events: Array[Dictionary] = []

## The ground. Null means a featureless field, which is what every unformed test
## battle and every milestone before this one ran on.
var terrain: BattlefieldTerrain = null
## The bodies of soldiers. Empty means every soldier fights for itself, which is the
## pre-formation behaviour and is kept working on purpose.
var formations: Array[BattleFormation] = []

## Unit id -> unit. Rebuilt only when the roster changes, so a lookup during a step is
## a probe rather than a walk of the whole battlefield.
var _unit_by_id: Dictionary = {}
var _formations_by_id: Dictionary = {}

## The proximity index. Every spatial question the battle asks goes through this, and
## it is rebuilt once per tick. See [BattleSpatialGrid].
var grid: BattleSpatialGrid = null
## Scratch array for spatial queries, owned by the simulator and reused by every query
## so that a tick does not allocate one array per soldier. The query clears it.
var _query_scratch: Array[BattleUnit] = []
## The fastest living soldier, cached because it only changes when the roster does. The
## grid needs it to know how far a unit may have walked since the last rebuild.
var _fastest_speed: float = 0.0

## Target search shape, from config. The starting radius is deliberately larger than
## any reach in the game so that a soldier never has to escalate to find somebody it
## could actually hit; the escalation is for the quiet cases, and the ceiling exists so
## that a search always terminates.
var target_search_radius: float = 8.0
var target_search_escalation: float = 4.0
var target_search_max_radius: float = 60.0

## ---------- target persistence and reacquisition cadence (Step 7.4) --------
##
## [b]The rule.[/b] Once a soldier has acquired an automatic opponent, that opponent
## stays the answer while it is alive, hostile and still nearby. The soldier looks for a
## new one when the current one stops qualifying, or when its own awareness tick comes
## round - and never merely to discover that the same enemy is still standing in front of
## it. See D-080.
##
## [b]Why a cadence rather than merely "on invalidation".[/b] Waiting for an invalidation
## alone would leave a soldier holding an opponent it cannot touch while a fresh one
## walks into its face: an army that has marched past its own targeting. The cadence is
## what lets a soldier notice that the situation has changed, and it is staggered so that
## the noticing is spread across ticks rather than massed on one.

## How many simulation ticks may pass between a soldier's own awareness searches.
##
## One means "search every tick", which is the behaviour this milestone replaced. Four is
## the shipped value, chosen by sweeping 1, 2, 3, 4, 6 and 8 on both benchmark families:
## see D-081 for the figures and for what the behaviour costs at each.
var target_reacquisition_ticks: int = 4

## ---------- formation-driven engagement tunables (D-105) -------------------
## Every one of these is a knob rather than a law: the defaults are what the milestone measured,
## and a benchmark or a test can move any of them from config to see what the layer costs and
## what it buys. See D-105.
##
## Ticks between a body re-checking which enemy body it is fighting. The layer's main cost knob.
var engagement_recheck_ticks: int = ENGAGEMENT_RECHECK_TICKS
## Ticks a body that has stopped fighting keeps believing it may come back to one.
var engagement_disengage_ticks: int = ENGAGEMENT_DISENGAGE_TICKS
## Whether a body decides its press-forward gate once a step instead of every soldier asking for
## himself. On by default and switchable off, so a benchmark can run the reference in this same build,
## tick for tick - the only honest way to attribute a difference to it. See D-112's consequence.
var press_forward_cache_enabled: bool = true
## Whether the target loop's per-soldier sub-item timers run. They are `Time.get_ticks_usec()` reads -
## about four a soldier a tick - and D-112's own rule for a hot path is counts, not per-soldier timers.
## On by default so existing logs stay comparable, switchable off with `PB_TGT_TIMING=off`, in which case
## the phase marks stay and the sub-item breakdown reads zero. See D-116.
var target_timing_enabled: bool = true

## Whether the formed-soldier fast path in `_focus_target` is spelled out instead of going through
## `_side_index()`, `_focus_unit_of()`, `is_focus_current()` and `is_alive()` - four calls to answer a
## question the body already knows. On by default, switchable off with `PB_FOCUS_INLINE=method`, so a
## benchmark can run the previous shape in this same build. See D-115.
var focus_inline_enabled: bool = true

## Whether the native position mirror spells its guard out inline instead of calling
## `can_answer_natively()`. On by default and switchable off with `PB_NATIVE_GUARD=call`, for the same
## reason as everything else here: a paired run in one build beats a comparison against an old log.
var native_guard_inlined: bool = true
## Whether the native mirror's position writes are batched into one call per flush instead of one per
## moving soldier: appended as soldiers move, written before the next query and once at the end of the
## step. On is the shipped behaviour; `PB_NATIVE_BATCH=off` restores the per-call path exactly, so the
## two can be compared in one build. See D-118.
var native_batch_enabled: bool = true
## Whether `_move_toward` applies the terrain speed rule inline instead of calling `_effective_speed`,
## and reads the ground through the terrain's one-call fast path instead of its cell-index chain. On by
## default, switchable off with `PB_TERRAIN_FAST=off`, which restores the previous path exactly.
var terrain_speed_inline: bool = true
## Whether soldiers standing in their places take their body's own step instead of deriving it. On
## by default, and switchable off from config or [code]PB_RIGID_GROUPS=off[/code] so that a benchmark
## can run the per-soldier architecture in this same build, tick for tick - which is the only honest
## way to attribute a difference to it. See D-108.
var rigid_groups_enabled: bool = true
## Slack beyond the two bodies' reach, for the contact band.
var engagement_band_slack: float = CONTACT_BAND_SLACK
## Whether soldiers are held to their body's engagement at all. On by default, and switchable
## off from config or PB_ENGAGEMENT=off so that a benchmark or a test can run the architecture
## this milestone replaced, in this build, tick for tick - which is the only honest way to
## attribute a difference to it. See D-105.
var engagement_enabled: bool = true
## How much nearer a rival enemy body must be before a body changes its mind.
var engagement_switch_advantage: float = ENGAGEMENT_SWITCH_ADVANTAGE
## How far past the band a body watches for enemy bodies it might have to answer to.
var engagement_nearby_margin: float = ENGAGEMENT_NEARBY_MARGIN
## Ticks a soldier may strike back at whoever last struck it.
var retaliation_ticks: int = RETALIATION_TICKS
## The formation catalog, kept for any body this battle has to create - a split is a deployment.
var _formation_catalog: FormationCatalog = null

## How far a retained opponent may be before it stops being worth continuing with, in
## world units.
##
## Shipped equal to [member target_search_max_radius], and equal to it on purpose: a
## soldier should not release an opponent it was only just able to find because that
## opponent is now a unit further away. Swept at 8, 16, 24 and 32 (D-082); the values
## below the search ceiling make a soldier acquire an enemy at long range and let it go on
## the very next tick, which is thrash dressed up as a rule. What the bound is for is the
## opponent that genuinely leaves - the one that would otherwise be run after across the
## battlefield - and for that it only has to be finite and bounded by what a search could
## have found in the first place.
var target_retention_radius: float = 32.0

## How much closer a new candidate has to be before a soldier abandons the opponent it
## already has. 1.0 would switch on any difference at all; 1.25 means an enemy has to be
## a quarter closer to take over, which is the hysteresis that stops two similar enemies
## swapping the answer every tick. See D-081.
var target_switch_advantage: float = 1.25

## Whether losing an opponent that was within reach is allowed to bring the next search
## forward, instead of waiting for the soldier's own slot.
##
## This is the only path that can search off the cadence, and it is deliberately narrow:
## it fires when a soldier's sword was in something when that something was taken away,
## which is a fight continuing and not a schedule arriving. It is bounded by the size of
## the contact line rather than by the size of the army, and the death-storm test measures
## the worst tick it can produce. See D-083.
var target_immediate_on_contact_loss: bool = true

## How far from a lost opponent a soldier has to have been for its loss to count as being
## taken away mid-fight, as a multiple of the soldier's own reach. One means "it was
## within reach"; the knife-edge case is a soldier whose opponent died to somebody else's
## blow at the moment it was about to swing.
var target_contact_loss_factor: float = 1.0

## Who a soldier faces when nobody is near it, refreshed once per tick.
##
## A local search answers "who is nearest to me" for a soldier standing in the fighting,
## and that answer is the same one an exhaustive scan would have given (D-061). It cannot
## answer it for a soldier standing half a battlefield away: doing so requires looking at
## the whole enemy army, and paying that per soldier per tick is exactly the cost this
## milestone removed. Measured, it was ninety-seven per cent of the soldier loop.
##
## So the search has a bound. Inside it, a soldier finds its own nearest enemy. Outside
## it, the soldier stops asking a question about itself and is pointed at the fighting
## instead - by its body if it is formed, by its side if it is not. See D-067.
##
## [b]Step 7.5 moved where that answer lives.[/b] It used to be a dictionary keyed by
## formation id, rebuilt by a pass over the whole army per body per tick - the same shape of
## work as the per-soldier scan it had replaced, one level up, and measured at 881 ms a tick
## at twenty thousand soldiers (D-088). It is now a field on the body itself, filled once per
## tick from a summary built in a single pass (see the scratch state below), so reading it
## costs a field access rather than a hash lookup and computing it costs bodies rather than
## soldiers. See D-089.

## ---------- formation-focus scratch state (Step 7.5) ----------------------
##
## [b]Preallocated, and reused every tick.[/b] Focus selection runs once per body per tick,
## so anything it builds fresh is built a thousand times a second in a large battle. These
## buffers are allocated when the army is handed over and written into thereafter, which is
## what lets the milestone claim a steady-state tick with no allocation in the focus path at
## all - a claim the tests check rather than assume (D-091).
##
## They are plain arrays and packed arrays rather than objects because none of them is
## state: each is emptied and refilled within one pass, and nothing outside the focus code
## may read one.
##
## Candidate enemy buckets, both sides' runs in one buffer. A bucket names a place an enemy
## can be found: a non-negative code is an index into [member formations], and a negative one
## names a side's unformed soldiers (-1 the player's, -2 the enemy's). GDScript has no array
## views, so the two runs share the buffer and are read through the bounds below.
var _bucket_codes: PackedInt32Array = PackedInt32Array()
## Which buckets a single focus query has already opened, as a query stamp rather than a
## flag: a query writes its own id rather than clearing the array, so asking a question costs
## nothing proportional to the number of bodies.
var _bucket_taken: PackedInt32Array = PackedInt32Array()
## Where each side's run starts in [member _bucket_codes], and how long it is.
var _bucket_start: PackedInt32Array = PackedInt32Array([0, 0])
var _bucket_count: PackedInt32Array = PackedInt32Array([0, 0])
var _focus_query_id: int = 0
## The bucket the last selection answered from, or -1 for none: how a caller learns which
## body it was just pointed at without searching for it.
var _focus_last_bucket: int = -1

## The living soldiers of each side that belong to no body, in the order they were walked,
## and how many of each array is in use. Preallocated to the size of the army: a soldier is
## either in a body's summary or in its side's loose run, never both, so the two together can
## never exceed the roster.
var _loose_units: Array = []
var _loose_count: PackedInt32Array = PackedInt32Array([0, 0])
var _loose_sum: Array[Vector2] = [Vector2.ZERO, Vector2.ZERO]
var _loose_min: Array[Vector2] = [Vector2.ZERO, Vector2.ZERO]
var _loose_max: Array[Vector2] = [Vector2.ZERO, Vector2.ZERO]

## Per-side totals from the summary pass: how many of a side are standing and where their
## average is. The point a side with no bodies is pointed from.
var _side_living: PackedInt32Array = PackedInt32Array([0, 0])
var _side_sum: Array[Vector2] = [Vector2.ZERO, Vector2.ZERO]
## The tick the summaries describe. Checked by anything that reads one, so a reader that runs
## before the tick's focus pass gets a correct answer rather than last tick's.
var _summary_tick: int = -1
## Whether this tick's pass walked the army for the side totals and the unclaimed soldiers.
## False when every living soldier belongs to a body, in which case there was nothing for that
## walk to find and the side totals are worked out on demand by the one caller that wants them.
var _sides_built: bool = false
## The tick each side's centre was last worked out on, so a battle with no bodies pays for the
## walk at most once per side per tick rather than once per soldier.
var _side_centre_tick: PackedInt32Array = PackedInt32Array([-1, -1])
## How many soldiers the battle believes are standing, kept up as soldiers fall rather than
## counted. It is a hint and not a truth: if it is wrong it is wrong high, which makes the pass
## do the walk it would otherwise skip. Nothing downstream can be wrong because of it.
var _living_total: int = 0
## The side fallback's answer and the tick it was worked out on. Per side rather than per
## soldier: a soldier with no body to ask for it is asking its side, and its side is asked
## once - refreshed every tick, so a side keeps pointing at whoever is nearest to it rather
## than at whoever it met first and never noticed die, and re-asked inside a tick only when
## the answer it holds has been killed since it was worked out.
var _focus_by_side: Array = [null, null]
var _side_focus_tick: PackedInt32Array = PackedInt32Array([-1, -1])

## Development only: each body's focus answer on the previous tick, as a unit id, so the
## counters can say how often the answer changed. Never read by the game and only written
## behind [member profile_enabled].
var _focus_previous_id: PackedInt32Array = PackedInt32Array()

## The roster addressed by unit id, as an array rather than a dictionary.
##
## [member _unit_by_id] is the battle's index and stays the general one - orders, tooling and
## tests resolve a handful of ids through it. This is the same mapping for the one caller that
## resolves thousands of ids a tick: the summary pass reads a body's roll, and the hash lookup
## it used to do per soldier was a visible share of the focus phase on the fixed-area torture
## test. Built once when the roster is handed over, never written again, and null for an id
## nobody holds.
var _unit_slots: Array[BattleUnit] = []

## Per body, references to its living soldiers, rebuilt each tick alongside the summary.
##
## The same shape as the spatial grid's own index: membership is owned by the body as a list
## of ids, and anything that walks a body's soldiers repeatedly keeps references to them
## rather than resolving an id through the battle's dictionary once per soldier per question.
## Measured, the dictionary was the whole of the gap between this design and the one it
## replaced on the fixed-area torture test, where a body is ten thousand soldiers: 40,000
## lookups a tick, at something like three times the cost of an array read.
##
## Preallocated and reused, so a tick writes into it rather than building it.
var _body_members: Array = []
var _body_member_count: PackedInt32Array = PackedInt32Array()

## [b]The one place a body's focus soldier is referred to.[/b] Everything else the focus
## layer remembers about a body is a number, kept on the body; the soldier itself is kept
## here, indexed by the body's position in [member formations], because a body must not hold
## a soldier and a soldier holds its body. That reference would be a cycle, Godot's reference
## counting has no collector, and a battle that built one would leak every body and every
## soldier in it - which is exactly what a first attempt at this milestone did, and what the
## suite's leak check caught. See D-089.
##
## Sized to the formations a battle has, and read with [member BattleFormation.index].
var _focus_unit_by_body: Array[BattleUnit] = []

## The separation pass's own index. A second grid rather than the targeting one because
## the two ask different-sized questions: a target search reaches 8 units and a separation
## happens at 1.35, and one cell size cannot be right for both. See [BattleOverlapGrid]
## and D-073.
var overlap_grid: BattleOverlapGrid = null
## Cell size for the separation pass, in world units.
##
## One body's width - the separation distance itself, 1.35 - because that is the distance
## the pass cares about and nothing else. It makes the neighbourhood exactly one cell, so
## a cell is paired with the four cells in front of it and no further, which measured
## fastest of five sizes tried (0.45, 0.7, 0.9, 1.35, 2.0) at both two and five thousand
## soldiers on the fixed-area benchmark. See D-078.
##
## It is deliberately a separate number from [member cell_size] rather than a share of it.
## The targeting grid has to cover eight units and the separation pass has to cover one
## and a third; a single value cannot be right for both, and forcing one to be a multiple
## of the other would tie two tuning decisions together that have nothing to do with each
## other.
var overlap_cell_size: float = 1.35
## How close to its assigned place a soldier must be for its formation to be trusted to be
## keeping it off its own neighbours. Zero switches that optimisation off entirely.
var separation_settle_epsilon: float = 0.15
## The furthest one separation pass may displace a soldier. See
## [member BattleOverlapGrid.max_push].
var max_separation_push: float = 1.35

## The last pass's counters, copied out of the overlap grid so the report can be read
## without reaching into it. Development only. See D-071.
var overlap_stats: Dictionary = {}

## Development only, and only while the per-tick sampler is on: the separation pass's own
## report from the tick that cost the most. The average says what the pass usually costs and
## the worst tick says what a player would notice, but neither says what that tick was
## doing - this does, and "the worst tick measured 47,695 pairs and clamped 831 soldiers" is
## a different problem from "the worst tick was the first one, with a cold cache".
var overlap_worst_report: Dictionary = {}
var _overlap_worst_usec: int = 0

## Which implementation runs the separation pass. Chosen once, before the first tick, from
## the size of the army - never switched mid-battle, because a battle that changed its
## separation pass half way through would be a battle whose performance nobody could
## attribute. See Step 7.8's report for the measurements behind these numbers.
enum OverlapBackend { AUTO, GDSCRIPT, PACKED, NATIVE, COMPARE }

## -1 (the default) means AUTO: the threshold below decides. Anything else forces that pass,
## which is what the benchmark and the tests use.
var overlap_backend: int = OverlapBackend.AUTO

## The army sizes at which the separation pass's faster implementations start to pay for
## themselves. Both measured on this machine, in matched tick windows, with all three passes
## run over the same battles - the tables are in the Step 7.8 report and in the benchmark's
## `--overlap-sweep`.
##
## 1,000 is where the native pass stops being a rounding error and starts carrying the phase:
## at 1,000 soldiers on a realistic field it is 3.6x the reference's overlap phase and takes a
## fifth off the whole tick, and the ratio only widens from there (5.6x at 20,000). Below it the
## pass is a small share of a tick that is already cheap, and the accelerator's fixed per-tick
## cost is a larger share of what it saves. It is deliberately the same number the targeting
## kernel uses, so there is one "this is a real battle now" line in the project rather than two.
##
## 500 is the same argument for the packed pass, which has no boundary to amortise and no
## library to load: at 500 soldiers it is 1.5x the reference's phase, and at 100 the saving is
## inside the noise of a tick that costs two milliseconds.
const OVERLAP_NATIVE_MIN_UNITS := 1000
const OVERLAP_PACKED_MIN_UNITS := 500
## Set when the pass was chosen, for the report: what actually ran, not what was asked for.
var overlap_backend_active: int = OverlapBackend.GDSCRIPT


## A short name for one of those passes, for reports and benchmarks.
static func overlap_backend_label(backend: int) -> String:
	match backend:
		OverlapBackend.PACKED:
			return "packed"
		OverlapBackend.NATIVE:
			return "native"
		OverlapBackend.COMPARE:
			return "native+cmp"
		_:
			return "gdscript"

## Development-only timing accumulators. Off by default and free when off: every read
## of them is behind a boolean, and nothing is measured unless the benchmark asks.
## Deliberately coarse - phase-level, plus one pair of clock reads per soldier for
## targeting - because the point is to say which phase costs what, not to profile
## individual statements. See D-064.
var profile_enabled: bool = false
var profile: Dictionary = {}

## ---------- development-only target counters (Step 7.4) --------------------
##
## [b]Measurement before change.[/b] The phase clock could say that target selection cost
## 248 ms a tick at five thousand soldiers. It could not say *why*, and "the search is
## expensive" and "the search happens far too often" call for opposite fixes. So target
## handling was given counters first, and the counters chose the milestone.
##
## They count what the code did, not what it was asked to do: searches actually run,
## where the answer came from, why a remembered opponent was dropped, and how many
## candidates a search had to look at. Every one of them is incremented behind
## [member profile_enabled], so a real battle pays nothing for being explained. See D-079.
##
## The same counters are what turns the before/after comparison into a fact rather than a
## claim: the run that produced the "before" column differs from the run that produced
## the "after" column in behaviour and in nothing else.
var tgt_searches: int = 0
## Searches that found somebody, and searches that found nobody locally.
var tgt_successful_searches: int = 0
var tgt_empty_searches: int = 0
## How many searches were answered by each rung of the escalation ladder. Rung one is
## the starting radius; a rung count above one means the soldier had to widen its search,
## which is the pre-contact case rather than the fighting one.
var tgt_rung_hits: PackedInt32Array = PackedInt32Array()
## Soldiers pointed at the fighting because they had nobody of their own, without looking.
## The cheap fallback, counted so that "how often is it actually used" is a number. A tick
## where a search ran and found nobody is counted as a search instead, not as both: these
## counters partition soldier-ticks, and a set of counters that overlaps cannot be added up.
var tgt_focus_fallbacks: int = 0
## Of those, the ones where the look was skipped on a proof that it would have found nobody
## rather than merely not being due. A sub-count of [member tgt_focus_fallbacks], not a
## sixth category: it says how much of the cheap path was reached by arithmetic rather than
## by arriving at the soldier's turn.
var tgt_focus_proven: int = 0
## Explicit player orders honoured, and orders cleared because their quarry died.
var tgt_explicit_order_uses: int = 0
var tgt_order_clears: int = 0

## ---------- development-only kill-cleanup counters (Step 7.9) ----------------
##
## Every death walks the whole roster to clear the explicit orders that were hunting the soldier who
## fell - see `_attack`. That walk is O(roster) per death, so a tick that kills a front rank pays for
## the army once per corpse, and at twenty thousand soldiers with a hundred deaths a tick that is two
## million visits. It is the last suspected quadratic path in the per-soldier loop, which is the
## largest measured phase.
##
## Whether it is material is a hypothesis, and this milestone measures it rather than assuming it:
## the counters below count what the walk did (deaths that entered it, roster entries inspected,
## orders cleared, the largest single walk, and the walk's own elapsed time) so that the report can
## say whether an army-sized walk per death is worth a different data structure. Nothing is
## optimised until the numbers say so, and the counts are the primary result: when profiling is on
## the walk carries one boolean test per entry, so its timing is an upper bound rather than an exact
## cost. Every counter is incremented behind [member profile_enabled].
var kill_cleanup_deaths: int = 0
## Roster entries the cleanup walk inspected, across every death this reset.
var kill_cleanup_inspections: int = 0
## Orders cleared by the walk - the work it exists to do.
var kill_cleanup_clears: int = 0
## The largest number of entries any single death's walk inspected, because a kill storm's worst
## case is the number that decides whether this path matters, and an average hides it.
var kill_cleanup_worst_inspections: int = 0
## Microseconds the cleanup walks cost in total, as measured inside the walk itself.
var kill_cleanup_usec: int = 0

## ---------- development-only per-soldier counters (Step 7.11) ----------------
##
## The per-soldier loop is the largest measured phase of a tick - 203.1 ms of a 399.0 ms tick at twenty
## thousand soldiers in the Step 7.11 profile run - and target selection accounts for 72.1 ms of it. That
## leaves about 131 ms unexplained inside `_update_unit`, and the suspects are all cheap-looking
## per-soldier work rather than any one algorithm: a normalise and a range check for every soldier that
## has a target, a formation slot lookup for every formed soldier, and - the one that cannot be seen from
## GDScript at all - a call into the native grid for every soldier that moves, because the grid's
## mirrored positions are true only while these are the only writes of a live soldier's position (D-095).
##
## These counters say which paths the army actually takes, because a path that nobody walks cannot be
## the missing time. They count calls, not microseconds: per-soldier timers would cost more than the
## work they measure. Together with the probe's price per native call they turn "about 127 ms" into a
## number that names its cause. Every counter is incremented behind [member profile_enabled].
var upd_calls: int = 0
## Soldiers that resolved a target and therefore paid the facing normalise and the range check.
var upd_targeted: int = 0
## Soldiers already inside their attack range - the ones that strike instead of walking.
var upd_in_reach: int = 0
## Soldiers that took the formed path, and those inside it that pressed forward.
var upd_formed: int = 0
var upd_pressed_forward: int = 0
## Formation slot computations - one per formed soldier per tick, including those the rigid-group
## path then answers with the body's own step.
var upd_slot_lookups: int = 0
## Soldiers that took the rigid-group step (D-108) rather than dressing themselves.
var upd_rigid_steps: int = 0
## Calls to `_move_toward`, and the loose soldiers that walked to a player move order.
var upd_moves: int = 0
var upd_move_orders: int = 0
## Inside `_move_toward`: the direction normalise, the calls into the native grid, and the terrain
## lookups made by `_effective_speed`.
var mv_normalises: int = 0
var mv_native_calls: int = 0
var mv_terrain_lookups: int = 0

## ---------- the order index (Step 7.10) --------------------------------------
##
## Which soldiers are hunting which enemy, rebuilt once a tick.
##
## Clearing the orders that pointed at a soldier who has just died used to mean walking the whole
## roster once per death - O(deaths x army), measured at 98.3% of a twenty-thousand-soldier tick in a
## mass-casualty storm (D-110). The index turns that into a lookup: every soldier holding an order is
## chained onto the man he was ordered to kill, so a death clears exactly the men who were hunting it
## and inspects nobody else.
##
## Built as a snapshot, once a tick, like every other index in this project - there is no update path,
## so there is no update path to get wrong. Two integer arrays sized when the army is handed over, so
## nothing is allocated after [method add_units].
var _order_head: PackedInt32Array = PackedInt32Array()
var _order_next: PackedInt32Array = PackedInt32Array()
## The tick whose orders the chains describe. A direct `_attack()` call outside a tick - which the
## probe and the suites make - would otherwise be answered by an index built for a different tick, or
## by no index at all, and would silently clear nothing. Stale means rebuild.
var _order_index_tick: int = -1
## Ticks spent dealing with a remembered opponent rather than looking for one - the whole
## point of the milestone, split into the two cases that matter. [b]In reach[/b] is the
## fastest path through target handling: the enemy is close enough to be struck, so
## nothing at all is asked of the battlefield. [b]Not in reach[/b] is an opponent being
## walked towards or held at formation range.
var tgt_retained_in_reach: int = 0
var tgt_retained_held: int = 0
## Why a remembered opponent stopped being the answer. Dead is the common case in a
## fight; too far is a soldier that has stopped chasing; gone means the unit was not in
## the index at all; side would be a bug if it ever happened.
var tgt_invalid_dead: int = 0
var tgt_invalid_far: int = 0
var tgt_invalid_gone: int = 0
var tgt_invalid_side: int = 0
## Reacquisitions that were brought forward because the soldier's opponent was taken away
## from it mid-swing, and reacquisitions that simply ran on the soldier's own cadence.
var tgt_immediate_reacquires: int = 0
var tgt_scheduled_reacquires: int = 0
## Candidates handed over by the broadphase and actually measured, summed and at worst.
var tgt_candidates: int = 0
var tgt_candidates_max: int = 0
## Automatic opponent changes: how often a soldier dealing with one living enemy switched
## to a different living one. This is the churn figure, and the number hysteresis is
## meant to hold down. Acquisitions from nothing are counted separately so that a battle
## starting up does not look like churn.
var tgt_switches: int = 0
var tgt_acquisitions: int = 0
## Acquisition latency: how many ticks passed between a soldier losing an opponent and
## having another one, summed, worst, and over how many samples.
##
## This is the figure the cadence is judged by rather than the search count. A cadence
## makes looking cheaper; it must not make a soldier slow, and "slow" is measurable: the
## loss is stamped on the soldier, the replacement is stamped on the same soldier, and the
## difference is the answer in simulation ticks.
var tgt_latency_ticks: int = 0
var tgt_latency_worst: int = 0
var tgt_latency_samples: int = 0
## How many of those waits were longer than one cadence. A long wait is not the schedule
## arriving late - the schedule is bounded by the interval - it is a soldier with nobody
## left to find, standing at the edge of the fighting or on a wing that has not met
## anybody yet. The two are worth telling apart rather than averaging together.
var tgt_latency_over_cadence: int = 0
## Soldier-ticks: living soldiers multiplied by ticks stepped. The denominator for
## "searches per soldier per second", and the figure the old behaviour would have matched
## one search to, one for one.
var tgt_soldier_ticks: int = 0

## ---------- development-only focus counters (Step 7.5) --------------------
##
## [b]Measurement before change, for the second milestone running.[/b] Step 7.4's counters
## named the next bottleneck - formation focus, 881 ms a tick at twenty thousand soldiers -
## and could not say what made it expensive. "The formation scan is expensive" and "the
## formation scan happens once per soldier" are opposite diagnoses with opposite fixes, and
## reading the code cannot tell them apart: the code says a scan is run per formation per
## tick, and the question is whether that is what the battle actually does.
##
## So the focus path was counted before it was touched, in the three places a question can
## originate: a formation asking, a soldier asking, and a side asking on behalf of soldiers
## with no body to ask for them. Every counter is incremented behind
## [member profile_enabled], and the per-unit figures are added once per scan rather than
## once per unit examined, because a counter that costs as much as the thing it counts is
## not a measurement. See D-088.
var foc_passes: int = 0
## Focus evaluations: one per formation per tick, which is what the pass intends. A figure
## far above `formations x ticks` would mean the pass is running more than once a tick.
var foc_evaluations: int = 0
## Where the questions came from. A soldier-originated whole-army scan is the O(N^2) failure
## mode this milestone exists to remove, so it is counted separately from a formation-
## originated one rather than added together with it.
##
## [b]Since Step 7.5 the expected value of every one of these is zero[/b], because nothing in
## the focus path walks the army any more: the counters are kept, and asserted, so that
## "zero" is a measurement rather than a memory. See D-090.
var foc_scans_from_formations: int = 0
var foc_scans_from_soldiers: int = 0
var foc_scans_direct: int = 0
## Every call to [method _nearest_enemy_to_point], from anywhere. This is [b]the counter the
## brief asks for[/b]: how many whole-army scans the formation-focus logic performs.
var foc_global_scans: int = 0
## Units walked by those scans, split the same way. This is the figure that says whether a
## phase is expensive because it scans rarely and hugely or often and small.
var foc_units_examined: int = 0
var foc_units_from_formations: int = 0
var foc_units_from_soldiers: int = 0
## The bounded selection's own work: buckets whose box was measured, buckets actually opened,
## and soldiers walked inside the ones that were opened. Together with the summary pass these
## are the whole of the new cost, and `opened_per_evaluation` is the figure that says whether
## the bounds are doing their job or the search is degenerating into "look inside everything".
var foc_buckets_measured: int = 0
var foc_buckets_opened: int = 0
var foc_members_walked: int = 0
## Calls into [method _focus_target], and how each one was answered: by the cached formation
## answer, by repairing that answer, or by falling through to the side. They partition.
var foc_target_calls: int = 0
var foc_formation_hits: int = 0
var foc_formation_repairs: int = 0
var foc_side_uses: int = 0
var foc_side_repairs: int = 0
## How many times a side centre was asked for. A read of the summary pass now, where it used
## to be a walk of the army per ask.
var foc_side_centre_reads: int = 0
## Focus answers that changed from the previous tick, which is the churn figure a retention
## rule has to hold down.
var foc_changes: int = 0
## Arrays and dictionaries constructed on the focus path. Counted rather than assumed,
## because "this allocates nothing" is a claim that has to be tested.
var foc_allocations: int = 0
## The worst single tick for scans, units examined and changes, so a phase that averages
## well and spikes on one tick says so.
var foc_scans_worst_tick: int = 0
var foc_units_worst_tick: int = 0
var foc_changes_worst_tick: int = 0
var _foc_scans_this_tick: int = 0
var _foc_units_this_tick: int = 0
var _foc_changes_this_tick: int = 0

## ---------- development-only search-shape counters (Step 7.6) --------------
##
## [b]Measurement before change, for the third milestone running.[/b] Step 7.5's counters
## said automatic target acquisition costs 575 ms a tick at twenty thousand soldiers. They
## could not say what that money buys, and the phase is only asked on cadence - so the cost
## is not how many questions are asked. It is what one question costs, and only the search
## itself can answer that.
##
## Two figures decide the milestone. Cells inspected against cells *unique* to one search:
## a search paying mostly for ground it has already covered is one problem. Candidates
## measured against candidates found on the first rung: a search paying mostly to measure
## soldiers it then discards is a different problem, with a different fix. The counters
## exist to tell those apart before either is optimised. See D-092.
##
## Every counter is incremented behind [member profile_enabled], so a real battle pays
## nothing for being explained.
var tgt_grid_queries: int = 0
## Cells read across every rung, cells that the widest rung's box covers (the union, since
## the boxes are nested), and the difference - ground walked twice by one search.
var tgt_cells_inspected: int = 0
var tgt_cells_unique: int = 0
var tgt_cells_repeated: int = 0
## Searches that needed a second rung, searches that ended on the ceiling rung, and searches
## whose rungs did not all walk their box (an occupied-list walk reads only the soldiers who
## exist, so the union arithmetic does not describe it and those searches are counted out
## rather than folded in).
var tgt_searches_escalated: int = 0
var tgt_searches_at_ceiling: int = 0
## Searches whose rungs all walked their box, whose cells the union arithmetic describes,
## and searches that walked the occupied list instead - on a packed field the occupied list
## is the cheaper walk and the box is the wrong description of what was read.
var tgt_searches_clean: int = 0
var tgt_searches_mixed_walk: int = 0
var tgt_cells_clean: int = 0
var tgt_cells_mixed: int = 0
## Candidates the broadphase handed over, by rung. The first rung is the look a soldier makes
## when it expects to find somebody nearby; the deep rungs are the widening.
## Looks that widened and then found somebody at the wider radius. With the first-rung hits
## and the empty looks these partition the searches, which is what says whether the widening
## pays for itself or mostly proves emptiness.
var tgt_deep_hits: int = 0
var tgt_candidates_first_rung: int = 0
var tgt_candidates_deep_rungs: int = 0
## Time inside the grid query by rung, so "the widening costs the phase" is a measurement
## rather than an inference from the cell counts.
var tgt_usec_first_rung: int = 0
var tgt_usec_deep_rungs: int = 0
## Where the rest of the target phase goes. The grid query is only part of it - the phase
## also decides whether a remembered opponent is still worth keeping, proves whether a look
## is worth making, and answers with the formation when the look is over - and a milestone
## that optimised the query without knowing the size of those is a milestone that optimises
## the wrong thing. Each is timed behind the profile flag.
var tgt_us_retained: int = 0
var tgt_us_proof: int = 0
var tgt_us_improve: int = 0
var tgt_us_focus: int = 0
## Searches that found nobody locally and were answered by formation focus, split by where
## that answer actually came from. These partition with [member tgt_searches].
var tgt_empty_to_focus: int = 0
var tgt_empty_to_formation_focus: int = 0
var tgt_empty_to_side_focus: int = 0
## One sample per search, so the percentiles are exact rather than bucketed. Collected once
## per search rather than once per cell, which is why the collection costs a fraction of a
## per cent of the phase it describes.
var tgt_search_cells_samples: PackedInt32Array = PackedInt32Array()
var tgt_search_cand_samples: PackedInt32Array = PackedInt32Array()
var tgt_search_result_dist: PackedFloat32Array = PackedFloat32Array()
## A ceiling on those samples, so a long battle cannot grow them without bound. Reached only
## by runs far longer than any benchmark, and the report says when it was reached.
const TGT_SAMPLE_CAP := 400000
var tgt_samples_capped: bool = false

## Set for the duration of one soldier's target resolution when the invalidation that
## made the search necessary was an urgent one. Consumed by the search that follows it in
## the same call, and cleared before every resolution, so it never leaks between soldiers.
var _search_is_immediate: bool = false

## Per-tick phase samples for the spike analysis, collected only when
## [member sample_phases] is on. Average cost hides the thing this milestone is most
## likely to break: a system that averages well and spikes every sixth tick. See D-084.
var sample_phases: bool = false
var samples: Dictionary = {}

var field_size: Vector2 = Vector2(100.0, 60.0)
var separation_radius: float = 1.5
## The grid's cell size, in world units. Read from config so it is one number in one
## place rather than a constant arguing with itself in three files. See D-060.
var cell_size: float = 4.0
var base_hit_chance: float = 0.75
var defence_mitigation: float = 0.05
var max_duration: float = 600.0
## How close an engaged body brings its centre to the enemy's before it considers the
## lines to have met. Small: the ranks are what actually touch.
var contact_gap: float = 1.5


func _init(p_config: GameConfig, battle_seed: int = 0) -> void:
	config = p_config
	rng = RandomNumberGenerator.new()
	rng.seed = battle_seed
	if config != null:
		field_size = BattleSetup.field_size(config)
		separation_radius = config.get_float("battle.separation_radius", 1.5)
		base_hit_chance = config.get_float("battle.base_hit_chance", 0.75)
		defence_mitigation = config.get_float("battle.defence_mitigation", 0.05)
		max_duration = config.get_float("battle.max_duration_seconds", 600.0)
		contact_gap = config.get_float("formation.enemy_contact_gap", 1.5)
		cell_size = maxf(0.25, config.get_float("battle.spatial_cell_size", 4.0))
		overlap_cell_size = maxf(0.05, config.get_float("battle.overlap_cell_size", 1.35))
		separation_settle_epsilon = maxf(0.0, config.get_float("battle.separation_settle_epsilon", 0.15))
		max_separation_push = maxf(0.01, config.get_float("battle.max_separation_push", 1.35))
		target_search_radius = maxf(0.5, config.get_float("battle.target_search_radius", 8.0))
		target_search_escalation = maxf(1.05, config.get_float("battle.target_search_escalation", 4.0))
		target_search_max_radius = config.get_float("battle.target_search_max_radius", 32.0)
		# The bound is what keeps a target search local. A ceiling of zero - or anything
		# below the starting radius - would mean a per-soldier search of the whole
		# battlefield, which is precisely the cost this milestone exists to remove, so it is
		# repaired to the starting radius rather than honoured. See D-067.
		target_search_max_radius = maxf(target_search_radius, target_search_max_radius)
		# Step 7.4. A cadence of zero or less would mean "never look again", which is not a
		# cadence and would strand every soldier on the first enemy it ever met, so it is
		# repaired to one tick - the every-tick behaviour - rather than honoured.
		target_reacquisition_ticks = maxi(1, int(config.get_int("battle.target_reacquisition_ticks", 4)))
		engagement_recheck_ticks = maxi(1, int(config.get_int(
			"battle.engagement_recheck_ticks", ENGAGEMENT_RECHECK_TICKS)))
		engagement_disengage_ticks = maxi(0, int(config.get_int(
			"battle.engagement_disengage_ticks", ENGAGEMENT_DISENGAGE_TICKS)))
		engagement_band_slack = maxf(0.0, config.get_float(
			"battle.engagement_band_slack", CONTACT_BAND_SLACK))
		engagement_switch_advantage = maxf(1.0, config.get_float(
			"battle.engagement_switch_advantage", ENGAGEMENT_SWITCH_ADVANTAGE))
		engagement_nearby_margin = maxf(0.0, config.get_float(
			"battle.engagement_nearby_margin", ENGAGEMENT_NEARBY_MARGIN))
		retaliation_ticks = maxi(0, int(config.get_int("battle.retaliation_ticks", RETALIATION_TICKS)))
		engagement_enabled = config.get_bool("battle.engagement_enabled", true)
		rigid_groups_enabled = config.get_bool("battle.rigid_groups_enabled", true)
		press_forward_cache_enabled = config.get_bool("battle.press_forward_cache_enabled", true)
		native_guard_inlined = config.get_bool("battle.native_guard_inlined", true)
		terrain_speed_inline = config.get_bool("battle.terrain_speed_inline", true)
		focus_inline_enabled = config.get_bool("battle.focus_inline_enabled", true)
		target_timing_enabled = config.get_bool("battle.target_timing_enabled", true)
		if OS.get_environment("PB_TGT_TIMING").to_lower() in ["off", "0", "false", "no", "counts"]:
			target_timing_enabled = false
		if OS.get_environment("PB_FOCUS_INLINE").to_lower() in ["method", "call", "off", "0", "false", "no"]:
			focus_inline_enabled = false
		if OS.get_environment("PB_TERRAIN_FAST").to_lower() in ["off", "0", "false", "no"]:
			terrain_speed_inline = false
		if OS.get_environment("PB_NATIVE_GUARD").to_lower() in ["call", "method", "off", "0", "false", "no"]:
			native_guard_inlined = false
		native_batch_enabled = config.get_bool("battle.native_batch_enabled", true)
		if OS.get_environment("PB_NATIVE_BATCH").to_lower() in ["off", "0", "false", "no", "call"]:
			native_batch_enabled = false
		if OS.get_environment("PB_PRESS_CACHE").to_lower() in ["off", "0", "false", "no"]:
			press_forward_cache_enabled = false
		if OS.get_environment("PB_RIGID_GROUPS").to_lower() in ["off", "0", "false", "no"]:
			rigid_groups_enabled = false
		# The environment variable is what lets a benchmark or CI hold the layer still - off is
		# the architecture this milestone replaced, in the same build. See D-105.
		if OS.get_environment("PB_ENGAGEMENT").to_lower() in ["off", "0", "false", "no"]:
			engagement_enabled = false
		target_retention_radius = maxf(0.0, config.get_float("battle.target_retention_radius", 32.0))
		target_switch_advantage = maxf(1.0, config.get_float("battle.target_switch_advantage", 1.25))
		target_immediate_on_contact_loss = config.get_bool("battle.target_immediate_on_contact_loss", true)
		target_contact_loss_factor = maxf(0.0, config.get_float("battle.target_contact_loss_factor", 1.0))
	grid = BattleSpatialGrid.new()
	grid.native_guard_inlined = native_guard_inlined
	grid.native_batch_enabled = native_batch_enabled
	grid.configure(field_size, cell_size)
	# The pass is built as the locked reference here and replaced by the measured best path in
	# start(), which is the earliest point the army size is known and the last point before a
	# tick could read it.
	overlap_grid = BattleOverlapGrid.new()
	overlap_grid.configure(field_size, overlap_cell_size)
	overlap_grid.max_push = max_separation_push
	overlap_backend_active = OverlapBackend.GDSCRIPT


func add_units(p_units: Array[BattleUnit]) -> void:
	units = p_units
	_unit_by_id.clear()
	_fastest_speed = 0.0
	_prepare_focus_buffers()
	_summary_tick = -1
	_focus_by_side = [null, null]
	_side_focus_tick = PackedInt32Array([-1, -1])
	# A soldier's awareness slot is derived from its own id and nothing else, which is
	# what makes the schedule deterministic: the same roster in the same order gives the
	# same phases, and re-ordering the roster changes the order soldiers are updated in
	# but not when any one of them looks around. See D-080.
	var interval := maxi(1, target_reacquisition_ticks)
	_living_total = 0
	# The highest unit id in the army, so the order index can be sized to address ids directly.
	var highest_id := 0
	for unit in units:
		_unit_by_id[unit.id] = unit
		unit.auto_target_id = -1
		unit.summary_tick = -1
		if unit.is_alive():
			_living_total += 1
		unit.next_search_tick = posmod(unit.id, interval)
		if unit.is_alive():
			_fastest_speed = maxf(_fastest_speed, unit.move_speed)
		highest_id = maxi(highest_id, unit.id)
	# The order index is sized here, with everything else that must not allocate later. Its chains are
	# addressed by unit id, so it is sized to the highest id in the army rather than to the count.
	_order_head.resize(highest_id + 1)
	_order_next.resize(highest_id + 1)
	_order_head.fill(-1)
	_order_next.fill(-1)


## The unit index. Exposed for tooling and tests that need to resolve many ids at
## once - the cohesion measure takes it directly, and reaching into a private field
## from outside would be the sort of coupling this project keeps out of its tests.
func units_by_id() -> Dictionary:
	return _unit_by_id


## ---------- terrain ------------------------------------------------------

## Build this battle's ground from the context's seed. Deterministic: the same
## context always produces the same battlefield.
func set_terrain_from_context(context: BattleContext, p_config: GameConfig = null) -> BattlefieldTerrain:
	if context == null:
		return null
	var source := p_config if p_config != null else config
	terrain = BattlefieldTerrain.generate(context.terrain_seed, field_size, source)
	return terrain


func set_terrain(p_terrain: BattlefieldTerrain) -> void:
	terrain = p_terrain


## ---------- formations ---------------------------------------------------

func add_formation(formation: BattleFormation) -> void:
	if formation == null:
		return
	# Position in the list is the body's address: the focus layer indexes summaries and
	# answers by it, so it is assigned here, once, and never changes. Bodies are added to a
	# battle and never taken out of it, which is what makes the position stable.
	formation.index = formations.size()
	formations.append(formation)
	_formations_by_id[formation.id] = formation
	if _focus_unit_by_body.size() < formations.size():
		_ensure_focus_arrays()


## Size the focus layer's per-body arrays to the formations the battle has, filling any new
## slot with "no answer yet". Called when a body is added and when the development counters
## are reset, because a per-body array that is shorter than the list of bodies is an index
## error waiting for the first tick - and an index error inside the pass would end the pass
## early, which is the one kind of bug a development counter must never be able to cause.
func _ensure_focus_arrays() -> void:
	var wanted := formations.size()
	_focus_unit_by_body.resize(wanted)
	var previous := _focus_previous_id.size()
	_focus_previous_id.resize(wanted)
	for i in range(previous, wanted):
		_focus_previous_id[i] = -1
	if _body_members.size() >= wanted and _body_member_count.size() >= wanted:
		return
	if profile_enabled:
		# The buffers a body costs, counted where they are actually made rather than
		# described in a comment (D-091).
		foc_allocations += 2
	_body_member_count.resize(wanted)
	var had := _body_members.size()
	_body_members.resize(wanted)
	for i in range(had, wanted):
		var bucket: Array[BattleUnit] = []
		_body_members[i] = bucket


func formation(formation_id: String) -> BattleFormation:
	var found: Variant = _formations_by_id.get(formation_id)
	return found as BattleFormation


func formations_of(side: String) -> Array[BattleFormation]:
	var out: Array[BattleFormation] = []
	for formation in formations:
		if formation.side == side:
			out.append(formation)
	return out


## Put a set of soldiers into a formation, in the order given.
##
## Membership is rebuilt from the list rather than appended to, so the result does not
## depend on what the formation held before - which is what makes an assignment
## reproducible. Nobody is moved by this: each soldier is told where its place now is
## and walks there itself.
##
## A soldier belongs to one body. Anyone in the list is taken out of whatever formation
## held them first. Both the donor's membership and the receiving body's membership are
## changed through [BattleFormation]'s own API and never by editing a list from out
## here, so each affected body invalidates its own geometry. Step 7 edited the donor's
## list directly, which left a formation that had just been detached from still
## reporting the frontage and rank count of a body it no longer was. See D-054.
func assign_formation(formation: BattleFormation, unit_ids: Array[int]) -> void:
	if formation == null:
		return
	var wanted := {}
	for unit_id in unit_ids:
		wanted[unit_id] = true

	for other in formations:
		if other == formation:
			continue
		if other.remove_units(unit_ids) > 0:
			_sync_formation_slots(other)

	# Anyone still on this body's roll who was not asked for is leaving it.
	for existing in formation.unit_ids:
		if not wanted.has(existing):
			_release_unit(existing)
	# No ensure_slots() here: the body rebuilds its own geometry when its membership
	# changes, which is the whole point of routing membership through its API.
	formation.set_units(unit_ids)
	_sync_formation_slots(formation)


## Detach a soldier from whatever body holds it, without putting it in another one.
func _release_unit(unit_id: int) -> void:
	var unit: BattleUnit = _unit_by_id.get(unit_id)
	if unit != null:
		unit.formation_ref = null
		unit.slot_index = -1


func _sync_formation_slots(formation: BattleFormation) -> void:
	for i in formation.unit_ids.size():
		var unit: BattleUnit = _unit_by_id.get(formation.unit_ids[i])
		if unit != null:
			unit.formation_ref = formation
			unit.slot_index = i


func _update_formations(delta: float) -> void:
	for formation in formations:
		if formation.order == BattleFormation.ORDER_ENGAGE:
			formation.steer_toward(_engage_target_for(formation))
		# Whether the step the body is about to take is a straight one. A turning or reforming body
		# must not hand its soldiers a translation: they would keep their places relative to the
		# world instead of to the line, which is the opposite of what a wheel is for.
		var straight := not formation.is_turning() and not formation.is_reforming()
		var before := formation.anchor
		formation.advance(delta, _formation_speed(formation))
		formation.anchor_step = (formation.anchor - before) if straight else Vector2.ZERO
		formation.ensure_slots()
		formation.update_cohesion(_unit_by_id, _cohesion_reference(formation))


## Where a body that has been told to close with the enemy wants its centre to be.
##
## [b]The station is where the two bodies' surviving fronts meet.[/b] A body stops when the
## ranks it still has are touching the ranks the enemy still has - measured from the
## forward-most place each body has a living man standing, not from the depth its layout was
## drawn with. For two intact bodies those are the same number, so nothing about an
## un-fought battle changes; they part company exactly when casualties have opened the
## ranks, and there the difference is the whole point. A line whose front rank has been
## killed has to walk its next rank into the enemy to keep fighting, and it cannot while its
## centre is held at the depth of a body it no longer has.
##
## [b]A body never steers inside the enemy.[/b] The station is always at least [member
## contact_gap] in front of the hostile centre, so a body's centre cannot be driven into -
## let alone through - the body it is closing on. This is what the previous rule did: an
## engaged body with nobody in contact aimed at the enemy's [i]anchor[/i] and walked its
## centre onto it, which left the two bodies' surviving ranks on one lattice a single
## spacing apart - just outside every melee reach - and froze a 300 v 300 battle with both
## armies still standing. See D-100.
##
## [b]Contact is a property of a body, not of a side.[/b] Whether the rest of the army is
## fighting is not this body's business: a wing that has not reached the enemy closes while
## the centre is engaged. See D-056.
##
## The walk this costs is over the body's own roll, twice - its own front and its target's -
## and it happens where the body is already walking its roll to work out its pace. See
## [method _surviving_front].
func _engage_target_for(formation: BattleFormation) -> Vector2:
	# The body's own choice of enemy, when it has one: the engagement layer works it out once
	# per cadence with hysteresis, where this used to scan for the nearest body every tick.
	# The scan remains the fallback for the first tick of a battle and for a body whose target
	# has just died. See D-105.
	var target := formation(formation.target_formation_id)
	if target == null or target.living_count <= 0:
		target = _nearest_enemy_formation(formation)
	if target == null:
		return formation.anchor
	var to_target := target.anchor - formation.anchor
	var distance := to_target.length()
	if distance <= 0.0001:
		return formation.anchor
	var closing := to_target / distance
	var fronts := _surviving_front(formation, closing) + _surviving_front(target, -closing)
	var stop := maxf(0.0, fronts) + contact_gap
	return target.anchor - closing * stop


## How far in front of its centre a body still has a place to stand a living man, along
## [param direction].
##
## [b]The body's surviving frontage, not the shape it was deployed in.[/b] Casualties stay on
## a body's roll on purpose, so that a hole in the line stays a hole - and a hole is not a
## front. A rank that has been killed contributes nothing here, which is the difference
## between a formation that keeps fighting as it is worn down and one that stands at a
## correct distance from a body of men that is no longer there. See D-101.
##
## Measured on the slots rather than on where the soldiers are standing: the slot layout is the
## body's own statement about where its ranks are, and a soldier who has pressed forward on its
## own should not redefine where the whole body's front is. A body with nobody left standing has
## no front and answers zero.
##
## [b]The living members come from the tick's own summary rather than from the roll.[/b] The
## pass that counts a body's soldiers has already collected exactly the men this question is
## about - alive, on this body's side, with their places on the roll - so asking it again per
## member would be a dictionary probe and a method call per soldier per tick for an answer the
## battle already holds. It costs one tick of lag on a death, which is a worn rank arriving a
## fiftieth of a second later than it could have. Measured at twenty thousand soldiers in matched
## thirty-tick windows: reading the roll itself put 31.7 ms/tick on the formation phase, and this
## puts 0.9, with the whole tick 2.6 ms/tick slower than the build before the rule existed. See
## D-104.
##
## [b]Arithmetic rather than geometry, deliberately.[/b] A slot is
## [code]anchor + right * lateral + forward * forward_offset[/code] and both of those offsets are
## fixed by the soldier's place on the roll, so the projection is
## [code]lateral * (right . direction) + forward_offset * (forward . direction)[/code] - two
## scalars hoisted out of the loop and four integer operations per soldier. Building the slot
## positions and subtracting vectors would be the same answer at several times the cost.
func _surviving_front(body: BattleFormation, direction: Vector2) -> float:
	if body.index < 0 or body.index >= _body_member_count.size():
		return 0.0
	var count := _body_member_count[body.index]
	var members: Array[BattleUnit] = _body_members[body.index]
	if count <= 0 or members == null:
		return 0.0
	count = mini(count, members.size())
	var files := maxi(1, body.file_count)
	var half_files := float(files - 1) * 0.5
	var half_ranks := float(body.rank_count - 1) * 0.5
	var lateral_scale := body.right_vector().dot(direction) * body.spacing
	var forward_scale := body.forward().dot(direction) * body.spacing
	var front := -INF
	for i in count:
		var place: int = members[i].slot_index
		if place < 0:
			continue
		var projection := (float(place % files) - half_files) * lateral_scale \
			+ (half_ranks - float(place / files)) * forward_scale
		if projection > front:
			front = projection
	return 0.0 if front == -INF else front


## The nearest opposing body. Bodies are few - one or two a side - so this is a short
## loop over a short list, not a battlefield-wide search.
func _nearest_enemy_formation(formation: BattleFormation) -> BattleFormation:
	var best: BattleFormation = null
	var best_distance := INF
	for other in formations:
		if other.side == formation.side or not other.has_living_units(_unit_by_id):
			continue
		var distance := formation.anchor.distance_squared_to(other.anchor)
		if distance < best_distance:
			best_distance = distance
			best = other
	return best


## ---------- formation-driven engagement (Step 7.8, D-105) -----------------
##
## [b]The rule.[/b] A body knows which enemy body it is facing, and a soldier of that body is
## asked to look for an opponent of its own only when the fight could actually be about it:
## when it stands within a weapon's reach of an enemy body close enough to matter, when it is
## being struck (and then it strikes back at its attacker directly, which costs one index
## probe and no search at all), or when the player has ordered it at something. Everyone else
## keeps the opponent it already had and dresses to its place, which is what a rear rank is
## for.
##
## [b]Why this is a fair thing to do.[/b] The work removed is a soldier asking the battlefield
## a strategic question - "which individual enemy should I attack" - when its body has already
## answered the strategic question for itself, once, and hands the answer down. The work that
## remains is local: the men who can reach each other still choose their own opponents, keep
## them across ticks, and fight them. Nothing about a soldier's individuality changes; what
## changes is who is asked to search. A soldier with no body to ask keeps the pre-formation
## behaviour exactly: it is its own formation, and searches on its own behalf.

## How often a body re-checks its target and its state. A tenth of a second of battle, which is
## far faster than a body can walk out of a range band.
const ENGAGEMENT_RECHECK_TICKS := 10
## How long a body that has stopped fighting holds DISENGAGING before it is merely en route
## again. Long enough that a line pushed apart and pushed back together is one engagement.
const ENGAGEMENT_DISENGAGE_TICKS := 40
## Slack beyond the two bodies' reach: one rank of spacing, so the men behind the front rank
## are already allowed to look as the front rank comes into reach, plus room for a step of
## movement between the check and the fight.
const CONTACT_BAND_SLACK := 2.6
## How much nearer another enemy body must be before a body changes its strategic target - the
## same hysteresis a soldier's own target gets, for the same reason (D-081): two similar
## answers must not swap on alternate checks.
const ENGAGEMENT_SWITCH_ADVANTAGE := 1.25
## How far beyond the contact band a body watches for enemy bodies it might have to answer to.
## Covers the flankers, and costs one box distance per enemy body on the re-check tick.
const ENGAGEMENT_NEARBY_MARGIN := 12.0
## A soldier struck within this many ticks may strike back at whoever struck it.
const RETALIATION_TICKS := 20

## Bodies with a living enemy body to face this tick.
var fdr_bodies_targeted := 0
## Bodies whose soldiers are being told to look for their own opponents - in contact or about
## to be.
var fdr_bodies_engaged := 0
## Soldiers currently allowed to look for their own opponent, maintained as a running total:
## promoted on the tick their awareness comes round, demoted when the geometry stops asking,
## and dropped when they die. Exact every tick and free every tick.
var fdr_promoted_soldiers := 0
## Searches the old architecture would have made this battle, that the gate refused: the
## soldier's awareness came round and it was not its fight.
var fdr_searches_avoided := 0
## Searches the gate allowed.
var fdr_searches_allowed := 0
## Soldiers moved from formation-driven to individual-aware, and back.
var fdr_promotions := 0
var fdr_demotions := 0
## Strikes returned by a soldier at whoever struck it, which needed no search.
var fdr_retaliations := 0


## Work out what every body is fighting and how close it is. A body pass on a cadence: a
## hundred bodies is a few thousand box distances every ten ticks, which is nothing next to
## the individual searches it stands in front of.
##
## Runs after the summaries are built (bounds, living counts and reaches are this tick's) and
## before the contact flags are cleared, because it reads the contact the soldiers established
## last tick to decide whether a body is still fighting or merely was.
func _update_engagement() -> void:
	# The pass reads the bodies' summaries, so a caller that has not built them this tick would
	# be asking about bodies that have no bounds, no living count and no reach. The runtime
	# always has them by this point; tooling and tests do not, and a layer that silently does
	# nothing when it is asked too early is worse than one that pays for a summary it needed.
	if not formations.is_empty() and not formations[0].summary_ready:
		_refresh_summaries()
	fdr_bodies_targeted = 0
	fdr_bodies_engaged = 0
	for formation in formations:
		if formation.in_contact:
			formation.last_contact_tick = tick_index
		if formation.index < 0 or not formation.is_living():
			formation.target_formation_id = ""
			formation.engagement = BattleFormation.ENGAGEMENT_NONE
			formation.contact_band = 0.0
			if not formation.nearby_enemy_ids.is_empty():
				formation.nearby_enemy_ids.clear()
			continue
		var recheck := tick_index >= formation.engagement_tick
		if not recheck:
			# A target that has died or been wiped out is not worth waiting for the cadence
			# over: the body re-chooses on this tick, and an explicit order that can no longer
			# be carried out lapses here rather than sitting on a body that is gone.
			var current := formation(formation.target_formation_id)
			if current == null or current.living_count <= 0:
				formation.target_formation_id = ""
				formation.target_explicit = false
				recheck = true
		if recheck:
			formation.engagement_tick = tick_index + engagement_recheck_ticks
			_choose_engagement_target(formation)
		var target := formation(formation.target_formation_id)
		if target == null or target.living_count <= 0:
			# Nobody left to fight. The body keeps its orders, its dressing and its place; no
			# soldier of it is asked to look for an enemy that is not there.
			formation.target_formation_id = ""
			formation.engagement = BattleFormation.ENGAGEMENT_NONE
			formation.contact_band = formation.max_range + engagement_band_slack
			if not formation.nearby_enemy_ids.is_empty():
				formation.nearby_enemy_ids.clear()
			continue
		fdr_bodies_targeted += 1
		formation.contact_band = formation.max_range + target.max_range + engagement_band_slack
		if formation.in_contact:
			formation.engagement = BattleFormation.ENGAGEMENT_IN_CONTACT
			fdr_bodies_engaged += 1
		elif tick_index - formation.last_contact_tick <= engagement_disengage_ticks:
			formation.engagement = BattleFormation.ENGAGEMENT_DISENGAGING
			fdr_bodies_engaged += 1
		elif target.bounds_distance_squared(formation.centre) \
				<= formation.contact_band * formation.contact_band:
			formation.engagement = BattleFormation.ENGAGEMENT_NEAR_CONTACT
			fdr_bodies_engaged += 1
		else:
			formation.engagement = BattleFormation.ENGAGEMENT_APPROACHING
		if recheck:
			_refresh_nearby_enemies(formation)


## Pick the enemy body this one is fighting. Deterministic: nearest living enemy body by box
## distance, ties broken by body id because the walk is over a deterministic array and the
## comparison is strict.
##
## [b]An explicit order wins outright.[/b] A body told to fight a particular body fights that
## body and does not drift onto a nearer one because the arithmetic prefers it. Otherwise the
## body keeps the answer it had unless somebody is clearly nearer
## ([constant engagement_switch_advantage]), which is the hysteresis that stops two similar
## answers exchanging places every re-check.
func _choose_engagement_target(formation: BattleFormation) -> void:
	if formation.target_explicit:
		var ordered := formation(formation.target_formation_id)
		if ordered != null and ordered.living_count > 0:
			return
		# The order has lapsed - the body it named is gone. Fall back to choosing, and say so
		# by dropping the flag rather than quietly keeping an order nobody can satisfy.
		formation.target_explicit = false
	var best := _nearest_enemy_formation(formation)
	if best == null:
		formation.target_formation_id = ""
		return
	var current := formation(formation.target_formation_id)
	if current != null and current.living_count > 0 and current != best:
		var keep := current.bounds_distance_squared(formation.centre)
		var challenger := best.bounds_distance_squared(formation.centre)
		if challenger * engagement_switch_advantage >= keep:
			return
	formation.target_formation_id = best.id


## The enemy bodies this body's soldiers might have to answer to: its target, plus any body
## whose box is within the band and a margin of this body's centre. Normally one entry - the
## common case is a single box distance per soldier - and more when the body is being taken in
## the flank or from behind, which is exactly when its soldiers must not be blind.
func _refresh_nearby_enemies(formation: BattleFormation) -> void:
	formation.nearby_enemy_ids.clear()
	var target_id := formation.target_formation_id
	if target_id != "":
		formation.nearby_enemy_ids.append(target_id)
	var reach := formation.contact_band + engagement_nearby_margin
	var reach_sq := reach * reach
	for other in formations:
		if other.side == formation.side or other.living_count <= 0 or other.id == target_id:
			continue
		if other.bounds_distance_squared(formation.centre) <= reach_sq:
			formation.nearby_enemy_ids.append(other.id)


## The body-level order behind "attack that formation". Explicit orders are authoritative: the
## body stops choosing until the named body is gone. See D-105.
func set_engagement_target(body: BattleFormation, enemy_id: String) -> void:
	if body == null:
		return
	var enemy := formation(enemy_id)
	if enemy == null or enemy.side == body.side:
		return
	body.target_formation_id = enemy_id
	body.target_explicit = true
	body.engagement_tick = tick_index + engagement_recheck_ticks
	_refresh_nearby_enemies(body)


## Whether this soldier may look for an opponent of its own on this awareness tick.
##
## Four ways to be allowed, and no fifth: an explicit order, a recently delivered blow, a body
## with nobody to fight (nobody to look for either), or standing within a weapon's reach of an
## enemy body that is close enough to matter. Everything else is a soldier whose body is
## marching or dressing, and whose fight has not started yet.
func _formation_driven_search_allowed(unit: BattleUnit) -> bool:
	if not engagement_enabled:
		return true
	if not unit.is_alive():
		# A dead soldier acquires nothing. The runtime never asks on behalf of one - the tick
		# walks the living - but the predicate has to say so on its own, because a rule that is
		# only true because nobody looks is not a rule. See D-105.
		return false
	var body := unit.formation_ref
	if body == null or body.index < 0:
		# No body: this soldier is its own formation, and the pre-formation behaviour is
		# exactly what it should get.
		return true
	if unit.attack_order_target_id >= 0:
		return true
	if unit.last_attacker_id >= 0 and tick_index - unit.last_attacked_tick <= retaliation_ticks:
		return true
	if body.nearby_enemy_ids.is_empty():
		return false
	var reach_sq := body.contact_band * body.contact_band
	for enemy_id in body.nearby_enemy_ids:
		var enemy: BattleFormation = _formations_by_id.get(enemy_id)
		if enemy == null or enemy.living_count <= 0:
			continue
		if enemy.bounds_distance_squared(unit.position) <= reach_sq:
			return true
	return false


## Count what the gate decided. Promotions and demotions are transitions of a per-soldier flag
## kept for exactly this: the counters are the milestone's evidence, so they are incremented
## where the decision is made rather than reconstructed afterwards.
func _note_search_decision(unit: BattleUnit, allowed: bool) -> void:
	if allowed:
		fdr_searches_allowed += 1
		if not unit.fdr_promoted:
			unit.fdr_promoted = true
			fdr_promotions += 1
			fdr_promoted_soldiers += 1
		return
	fdr_searches_avoided += 1
	if unit.fdr_promoted:
		unit.fdr_promoted = false
		fdr_demotions += 1
		fdr_promoted_soldiers = maxi(0, fdr_promoted_soldiers - 1)


## Strike back at whoever struck this soldier, if it struck it recently and is still standing.
## One index probe and no search: the blow was recorded by the damage step, so the body's
## attacker is known rather than looked for. This is what keeps a soldier taken in the flank or
## from behind from standing in its rank while its formation watches the other way.
func _retaliation_target(unit: BattleUnit) -> BattleUnit:
	if not engagement_enabled:
		return null
	if unit.last_attacker_id < 0 or tick_index - unit.last_attacked_tick > retaliation_ticks:
		return null
	var attacker: BattleUnit = _unit_by_id.get(unit.last_attacker_id)
	if attacker == null or not attacker.is_alive() or attacker.side == unit.side:
		return null
	if profile_enabled:
		fdr_retaliations += 1
	_store_target(unit, attacker)
	return attacker


## Every soldier's own view of the formation-driven layer, for the development view and the
## reports: promoted means "allowed to look for its own opponent".
func engagement_soldier_counts() -> Dictionary:
	var promoted := 0
	var formation_only := 0
	for unit in units:
		if not unit.is_alive():
			continue
		if unit.fdr_promoted:
			promoted += 1
		else:
			formation_only += 1
	return {"promoted": promoted, "formation_only": formation_only, "running_total": fdr_promoted_soldiers}


## ---------- dynamic membership: split, merge, ownership (Step 7.8, D-106) --
##
## A body is a roll of soldier ids plus the geometry that places them. Splitting is therefore a
## membership edit, not a battlefield rebuild: the soldiers keep their ids, their health, their
## kills and their history; they leave one roll and join another, and both bodies re-dress. No
## soldier is created, none is destroyed, and none can be in two rolls at once, because
## [method assign_formation] takes a soldier off whatever roll held it before it adds it -
## and [method check_membership_invariants] is what proves that after the fact rather than
## trusting it.

## Split a body in two. [param ids] leave, in any order and any size from one soldier to all
## but one; the rest stay. Returns the new body, or null when the request could not be honoured
## (nothing to move, everything to move, or the new id is already taken) - a split that would
## leave an empty body or move nobody is a rename, and the caller can see it did not happen.
##
## [b]Cost.[/b] One pass over the two rolls - the pass a body's summary already makes - plus the
## membership arrays being brought up to date. It is O(soldiers in the two bodies + bodies), not
## a walk of the battlefield and not a rebuild of anything. See D-106.
func split_formation(body: BattleFormation, ids: Array[int], new_id: String) -> BattleFormation:
	if body == null or ids.is_empty() or new_id == "" or formation(new_id) != null:
		return null
	var moving: Array[int] = []
	var seen: Dictionary = {}
	for unit_id in ids:
		if seen.has(unit_id) or not body.has_unit(unit_id):
			continue
		seen[unit_id] = true
		moving.append(unit_id)
	if moving.is_empty() or moving.size() >= body.unit_ids.size():
		return null
	var keep: Array[int] = []
	for unit_id in body.unit_ids:
		if not seen.has(unit_id):
			keep.append(unit_id)
	var split := BattleFormation.create(
		new_id, body.side, body.anchor, body.facing, body.type_id,
		_catalog_for_new_bodies(), config)
	split.order = body.order
	split.desired_facing = body.desired_facing
	split.target_anchor = body.target_anchor
	add_formation(split)
	# The moving soldiers go to the new body first, so that nobody is ever off a roll: the
	# invariant "a living soldier belongs to at most one body, and none of them is lost" is
	# about the moments in between as much as about the result.
	assign_formation(split, moving)
	assign_formation(body, keep)
	_refresh_summaries()
	return split


## Merge [param donor] into [param keeper]: every soldier of the donor joins the keeper's roll,
## in the donor's own order, and the donor leaves the battlefield. Returns false when the two
## cannot be merged (different sides, or the same body twice).
##
## A merged soldier keeps its id, health, kills and history exactly as a split soldier does:
## merging moves rolls, never soldiers. See D-106.
func merge_formations(keeper: BattleFormation, donor: BattleFormation) -> bool:
	if keeper == null or donor == null or keeper == donor or keeper.side != donor.side:
		return false
	var combined: Array[int] = []
	for unit_id in keeper.unit_ids:
		combined.append(unit_id)
	for unit_id in donor.unit_ids:
		combined.append(unit_id)
	assign_formation(keeper, combined)
	formations.erase(donor)
	_reindex_formations()
	# Any body that was facing the donor faces nobody: the body it named is off the battlefield,
	# and a name that resolves to nothing is how a stale target becomes a mystery later.
	for body in formations:
		if body.target_formation_id == donor.id:
			body.target_formation_id = ""
			body.target_explicit = false
	_refresh_summaries()
	return true


## Re-index the bodies after one has left the array, because the focus and summary arrays are
## addressed by a body's index and an index that no longer means what it did is a stale answer
## waiting to be read.
func _reindex_formations() -> void:
	for i in formations.size():
		formations[i].index = i
	_ensure_focus_arrays()


## The formation catalog, loaded once and kept for any body this battle has to create - a split
## is a deployment, and a deployment needs the layout definitions.
func _catalog_for_new_bodies() -> FormationCatalog:
	if _formation_catalog == null:
		_formation_catalog = FormationCatalog.load_from()
	return _formation_catalog


## Everything a formed battle must be able to say about its own membership, as a list of
## complaints - empty meaning the invariants hold. Walks every soldier, so it belongs to the
## tests and the development probe rather than to a tick.
##
## The list is written as sentences because it is read by a person looking at a failure, and a
## sentence that names the two bodies a soldier is standing in is worth more than a code.
func check_membership_invariants() -> Array[String]:
	# The check compares what a body reports against what it rolls, so it builds the summaries
	# first: a caller that has just killed somebody without stepping would otherwise be read as
	# a body whose count is wrong rather than as a body whose count is old. It is a tool, not a
	# tick, and walking the soldiers once is what makes its answers about the battle rather than
	# about when it was asked.
	if not formations.is_empty():
		_refresh_summaries()
	var problems: Array[String] = []
	var claimed: Dictionary = {}
	for body in formations:
		var counted := 0
		var slots := body.unit_ids.size()
		for i in slots:
			var unit_id := body.unit_ids[i]
			var unit: BattleUnit = _unit_by_id.get(unit_id)
			if unit == null:
				problems.append("%s rolls a soldier that does not exist: id %d" % [body.id, unit_id])
				continue
			if unit.side != body.side:
				problems.append("%s rolls a soldier of the other side: id %d" % [body.id, unit_id])
			if claimed.has(unit_id):
				problems.append("soldier %d stands in two bodies: %s and %s" % [
					unit_id, claimed[unit_id], body.id])
			claimed[unit_id] = body.id
			if unit.formation_ref != body:
				var where := "-" if unit.formation_ref == null else unit.formation_ref.id
				problems.append("soldier %d points at %s but is rolled in %s" % [unit_id, where, body.id])
			if unit.slot_index != i:
				problems.append("soldier %d carries slot %d but stands at place %d of %s" % [
					unit_id, unit.slot_index, i, body.id])
			if unit.is_alive():
				counted += 1
		if body.summary_ready and counted != body.living_count:
			problems.append("%s reports %d living soldiers but rolls %d" % [
				body.id, body.living_count, counted])
		if body.target_formation_id != "":
			var target := formation(body.target_formation_id)
			if target == null or target.living_count <= 0:
				problems.append("%s is targeting a body that is gone or empty: %s" % [
					body.id, body.target_formation_id])
	for unit in units:
		if not unit.is_alive():
			continue
		if unit.formation_ref != null and not unit.formation_ref.has_unit(unit.id):
			problems.append("soldier %d believes it is in %s, which does not roll it" % [
				unit.id, unit.formation_ref.id])
	return problems


## Forget the formation-driven counters. Maintained unconditionally rather than under the
## profiler, because they are the milestone's evidence, and reset when a battle starts or when
## something measuring the layer moves on to its next scenario.
func reset_engagement_counters() -> void:
	fdr_bodies_targeted = 0
	fdr_bodies_engaged = 0
	fdr_promoted_soldiers = 0
	fdr_searches_avoided = 0
	fdr_searches_allowed = 0
	fdr_promotions = 0
	fdr_demotions = 0
	fdr_retaliations = 0


## The formation-driven layer as numbers: what a benchmark or a test needs to say what the
## hierarchy bought, and what a report quotes instead of an impression.
func engagement_report() -> Dictionary:
	var counts := engagement_soldier_counts()
	var searches := fdr_searches_allowed + fdr_searches_avoided
	return {
		"soldiers": _living_total,
		"bodies": formations.size(),
		"bodies_with_target": fdr_bodies_targeted,
		"bodies_engaged": fdr_bodies_engaged,
		"promoted_soldiers": counts["promoted"],
		"formation_only_soldiers": counts["formation_only"],
		"running_promoted_total": fdr_promoted_soldiers,
		"searches_allowed": fdr_searches_allowed,
		"searches_avoided": fdr_searches_avoided,
		"searches_total": searches,
		"avoided_fraction": 0.0 if searches == 0 else float(fdr_searches_avoided) / float(searches),
		"promotions": fdr_promotions,
		"demotions": fdr_demotions,
		"retaliations": fdr_retaliations,
		"per_tick": _engagement_per_tick(),
	}


## The counters divided by the ticks the battle has run, for the per-tick figures a benchmark
## reports. Zero rather than a division by nothing on a battle that has not ticked.
func _engagement_per_tick() -> Dictionary:
	var ticks := maxi(1, tick_index)
	return {
		"searches_allowed": float(fdr_searches_allowed) / float(ticks),
		"searches_avoided": float(fdr_searches_avoided) / float(ticks),
		"soldier_share_allowed": 0.0 if _living_total <= 0
			else float(fdr_promoted_soldiers) / float(_living_total),
	}


## Whether this soldier may leave its place to restart a fight that has stopped
## happening.
##
## Three conditions, all of them narrow. The body must have been told to engage - a
## body told to hold holds, whatever the enemy is doing. The body must have stopped -
## a body still marching is dressing, not fighting. And [i]this body[/i] must have
## nobody within reach: if the line is fighting then the line is what matters and a
## soldier leaving it is a hole opening in it. A different formation on the same side
## being fully engaged is not a reason to freeze this one - that is precisely the wing
## that needs to be able to close.
func _can_press_forward(unit: BattleUnit, body: BattleFormation) -> bool:
	if body == null or unit.slot_index < 0:
		return false
	if not press_forward_cache_enabled:
		# The reference, kept switchable so the change can be measured against it in one build rather
		# than against an older log. This is exactly the code that shipped before the cache.
		if body.order != BattleFormation.ORDER_ENGAGE:
			return false
		if body.is_moving() or body.is_turning() or body.is_reforming():
			return false
		return not body.in_contact
	# The body-level half of this answer - the order, and whether the body is moving, turning or
	# reforming - is the same for every soldier in it and cannot change while the soldiers dress, so it
	# is decided once per body per step (see `press_forward_open`) instead of three calls per soldier.
	# Contact is not cached: soldiers set it part way through their own loop, so it is read live.
	if not body.press_forward_open:
		return false
	return not body.in_contact


## The pace of the whole body: set by its slowest soldier, so a formation never walks
## away from its own rear rank, and slowed further by the ground under its centre.
func _formation_speed(formation: BattleFormation) -> float:
	var slowest := INF
	for unit_id in formation.unit_ids:
		var unit: BattleUnit = _unit_by_id.get(unit_id)
		if unit != null and unit.is_alive():
			slowest = minf(slowest, unit.move_speed)
	if slowest == INF:
		return 0.0
	var factor := 1.0
	if config != null:
		factor = maxf(0.05, config.get_float("formation.move_speed_factor", 0.9))
	if terrain != null:
		factor *= terrain.move_multiplier_at(formation.anchor)
	return slowest * formation.move_factor * factor


## Distance at which a soldier counts as completely out of place, used to turn raw
## position error into a 0..1 cohesion figure.
func _cohesion_reference(formation: BattleFormation) -> float:
	var spacing := 3.0
	if config != null:
		spacing = maxf(0.1, config.get_float("formation.cohesion_reference_spacing", 3.0))
	return maxf(0.1, spacing * formation.spacing)



## The army size at which the accelerator starts to pay. Measured, not guessed: at 500
## soldiers the reference is 5% cheaper (the snapshot and the mirror are paid for a search
## that costs almost nothing), at 1,000 the accelerator is 1.8x cheaper, and the gap widens
## from there. Behaviour is identical either side of the threshold - only who answers the
## query changes - so this is a cost boundary, not a rule about battles. See D-095.
const TARGET_NATIVE_MIN_UNITS := 1000


func start() -> void:
	reset_engagement_counters()
	# A battle chooses its backend once, before the first tick, from the size of the army
	# it is about to run. Nothing switches mid-battle: the two implementations agree on
	# every answer, but a battle that changed backends half way through would be a battle
	# whose performance nobody could attribute.
	if OS.get_environment("PB_TARGET_BACKEND").to_lower() == "native":
		target_backend = BattleSpatialGrid.Backend.NATIVE_FULL
	elif target_backend == BattleSpatialGrid.Backend.GDSCRIPT and units.size() >= TARGET_NATIVE_MIN_UNITS:
		target_backend = BattleSpatialGrid.Backend.NATIVE_FULL
	select_overlap_backend()
	state = State.RUNNING
	elapsed = 0.0


## Choose the separation pass, once, from the army the battle is about to run. The thresholds
## are measurements rather than opinions: below the packed threshold the reference is already
## cheap enough that packing the field costs more than the pass saves, and above the native
## threshold the accelerator's boundary crossing is amortised. The environment variable is
## what lets CI and a benchmark hold one implementation still while measuring it.
func select_overlap_backend() -> void:
	var wanted := overlap_backend
	var forced := OS.get_environment("PB_OVERLAP_BACKEND").to_lower()
	if not forced.is_empty():
		match forced:
			"gdscript", "reference":
				wanted = OverlapBackend.GDSCRIPT
			"packed":
				wanted = OverlapBackend.PACKED
			"native":
				wanted = OverlapBackend.NATIVE
			"compare":
				wanted = OverlapBackend.COMPARE
	if wanted == OverlapBackend.AUTO:
		if units.size() >= OVERLAP_NATIVE_MIN_UNITS and BattleOverlapNative.available():
			wanted = OverlapBackend.NATIVE
		elif units.size() >= OVERLAP_PACKED_MIN_UNITS:
			wanted = OverlapBackend.PACKED
		else:
			wanted = OverlapBackend.GDSCRIPT
	if wanted == OverlapBackend.NATIVE and not BattleOverlapNative.available():
		# A missing accelerator is a slower tick, not a broken battle: the reference answers.
		wanted = OverlapBackend.GDSCRIPT
	overlap_backend_active = wanted
	var pass_object: BattleOverlapGrid = null
	match wanted:
		OverlapBackend.PACKED:
			pass_object = BattleOverlapGridPacked.new()
		OverlapBackend.NATIVE, OverlapBackend.COMPARE:
			var native_pass := BattleOverlapNative.new()
			native_pass.compare_enabled = wanted == OverlapBackend.COMPARE
			pass_object = native_pass
		_:
			pass_object = BattleOverlapGrid.new()
	pass_object.configure(field_size, overlap_cell_size)
	pass_object.max_push = max_separation_push
	overlap_grid = pass_object


func is_running() -> bool:
	return state == State.RUNNING


func is_finished() -> bool:
	return state == State.FINISHED


func find_unit(unit_id: int) -> BattleUnit:
	var found: Variant = _unit_by_id.get(unit_id)
	return found as BattleUnit


func alive_units(side: String = "") -> Array[BattleUnit]:
	var out: Array[BattleUnit] = []
	for unit in units:
		if not unit.is_alive():
			continue
		if side.is_empty() or unit.side == side:
			out.append(unit)
	return out


func side_count(side: String) -> int:
	return alive_units(side).size()


func enemy_side_of(side: String) -> String:
	return BattleContext.SIDE_ENEMY if side == BattleContext.SIDE_PLAYER else BattleContext.SIDE_PLAYER


## ---------- simulation ---------------------------------------------------

## Advance the battle by one real-time slice. Returns the events produced.
func step(delta: float) -> Array[Dictionary]:
	events = []
	if state != State.RUNNING:
		return events
	elapsed += delta
	if config != null and elapsed >= max_duration:
		# The battle is over the moment the clock runs out. Return immediately:
		# units must not move, strike, take damage or die after the fight has
		# officially ended, and no victory check may run either.
		_finish("")
		return events

	# The tick's starting point, for the spike analysis: the phase clocks are cumulative,
	# so a tick's own cost is the difference. Taken before anything runs and read back at
	# the end, because an average cost hides exactly the thing that matters here.
	var sample_mark: Dictionary = _sample_mark() if (profile_enabled and sample_phases) else {}

	# The bodies move first, then the soldiers dress to them. Doing it in this order
	# means a soldier reads one settled slot position per step rather than chasing a
	# place that is still being computed.
	var tick_start := _profile_start()
	var phase := _profile_start()
	_update_formations(delta)
	# One boolean per body per step, before the soldiers dress: the order and the moving/turning/
	# reforming predicates are the same for every soldier in a body and cannot change while the loop
	# runs, so deciding them once here removes three calls from every formed soldier's tick. Contact is
	# deliberately not part of it - soldiers set that themselves during the loop, so it stays live.
	for body in formations:
		if press_forward_cache_enabled:
			body.press_forward_open = body.order == BattleFormation.ORDER_ENGAGE \
				and not (body.is_moving() or body.is_turning() or body.is_reforming())
	_profile_stop("formation", phase)

	# One linear pass to index everyone, then every proximity question this tick is
	# answered locally. This is the whole of Step 7.2's cost model: the battlefield is
	# described once so that no soldier has to look at the battlefield.
	phase = _profile_start()
	_rebuild_spatial(delta)
	_profile_stop("grid", phase)

	# The hunters' chains, once a tick, for the same reason the spatial grid is rebuilt once a tick:
	# a death must not have to walk the army to find out who was hunting the man who fell. See D-111.
	phase = _profile_start()
	_rebuild_order_index()
	_profile_stop("orders", phase)

	# After the bodies have moved and before anyone asks, so a formation's focus is its
	# focus for this tick rather than for wherever it stood last tick.
	phase = _profile_start()
	_refresh_focus()
	_profile_stop("focus", phase)

	if engagement_enabled:
		# The body's own thinking, from the summaries just built: which enemy body it is
		# fighting and how close it is. Read below by every soldier's own awareness tick. The
		# pass is skipped entirely when the layer is switched off, so a baseline run measures
		# the architecture this one replaced rather than a gate that is always saying yes.
		# Deliberately before the contact flags are cleared, because it reads the contact the
		# soldiers established last tick to decide whether a body is still fighting or merely
		# was. See D-105.
		phase = _profile_start()
		_update_engagement()
		_profile_stop("engagement", phase)

	# Contact is read by the formation orders immediately above, and set by the soldiers
	# immediately below, so it is cleared in between. Clearing it at the end of the step
	# instead would wipe it before anyone could read it and every body would believe
	# itself unengaged forever; clearing it before the orders would do the same thing
	# one line earlier. After this step returns, each body holds the contact state its
	# own soldiers just established, which is what the view and the tests read.
	_clear_contact()

	# Two copies of the same loop, because the difference between them is the difference
	# between a benchmark and a battle. The measured path reads a clock twice per
	# soldier; the unmeasured one is exactly what it was before profiling existed, so a
	# normal battle pays nothing at all for the ability to measure one.
	if profile_enabled:
		for unit in units:
			if unit.is_alive():
				var soldier_probe := Time.get_ticks_usec()
				_update_unit(unit, delta)
				_profile_accumulate("soldiers", soldier_probe)
	else:
		for unit in units:
			if unit.is_alive():
				_update_unit(unit, delta)

	phase = _profile_start()
	_resolve_overlaps()
	_profile_stop("overlap", phase)

	_profile_stop("total", tick_start)
	if profile_enabled:
		profile["ticks"] = int(profile.get("ticks", 0)) + 1
	if sample_phases and not sample_mark.is_empty():
		_sample_tick(sample_mark)
	if grid != null:
		# Every move the tick made, written in one call if nothing asked a question first. The
		# mirror's end-of-tick state is what the next tick's snapshot is compared against, so it
		# is written here and not left in flight. See D-118.
		grid.flush_moves()
	# The tick counter moves last, so every decision taken during this tick saw the same
	# tick number. This is the only clock the target schedule reads, and it counts
	# simulation ticks rather than anything measured off a wall.
	tick_index += 1

	if not is_finished():
		_check_victory()
	return events


## Forget every body's contact state. One pass over the formations, which are few.
func _clear_contact() -> void:
	for formation in formations:
		formation.clear_contact()


## ---------- development-only profiling ------------------------------------
## Phase timing for the benchmark. Off by default, and free when off: every entry point
## returns immediately behind a boolean, and the one place that could have cost a call
## per soldier without profiling has two copies of its loop instead. See D-064.

func _profile_start() -> int:
	return Time.get_ticks_usec() if profile_enabled else 0


func _profile_stop(key: String, started: int) -> void:
	if not profile_enabled or started <= 0:
		return
	_profile_accumulate(key, started)


func _profile_accumulate(key: String, started: int) -> void:
	if started <= 0:
		return
	profile[key] = float(profile.get(key, 0.0)) + float(Time.get_ticks_usec() - started) / 1000.0


## Milliseconds accumulated for one phase, or zero if it never ran.
func profile_ms(key: String) -> float:
	return float(profile.get(key, 0.0))


func reset_profile() -> void:
	profile = {}
	samples = {}
	overlap_worst_report = {}
	_overlap_worst_usec = 0
	tgt_searches = 0
	tgt_successful_searches = 0
	tgt_empty_searches = 0
	tgt_rung_hits = PackedInt32Array()
	tgt_focus_fallbacks = 0
	tgt_focus_proven = 0
	tgt_explicit_order_uses = 0
	tgt_order_clears = 0
	kill_cleanup_deaths = 0
	kill_cleanup_inspections = 0
	kill_cleanup_clears = 0
	kill_cleanup_worst_inspections = 0
	kill_cleanup_usec = 0
	_order_index_tick = -1
	upd_calls = 0
	upd_targeted = 0
	upd_in_reach = 0
	upd_formed = 0
	upd_pressed_forward = 0
	upd_slot_lookups = 0
	upd_rigid_steps = 0
	upd_moves = 0
	upd_move_orders = 0
	mv_normalises = 0
	mv_native_calls = 0
	mv_terrain_lookups = 0
	tgt_retained_in_reach = 0
	tgt_retained_held = 0
	tgt_invalid_dead = 0
	tgt_invalid_far = 0
	tgt_invalid_gone = 0
	tgt_invalid_side = 0
	tgt_immediate_reacquires = 0
	tgt_scheduled_reacquires = 0
	tgt_candidates = 0
	tgt_candidates_max = 0
	tgt_switches = 0
	tgt_acquisitions = 0
	tgt_latency_ticks = 0
	tgt_latency_worst = 0
	tgt_latency_samples = 0
	tgt_latency_over_cadence = 0
	tgt_soldier_ticks = 0
	tgt_grid_queries = 0
	tgt_cells_inspected = 0
	tgt_cells_unique = 0
	tgt_cells_repeated = 0
	tgt_searches_escalated = 0
	tgt_searches_at_ceiling = 0
	tgt_searches_clean = 0
	tgt_searches_mixed_walk = 0
	tgt_deep_hits = 0
	tgt_cells_clean = 0
	tgt_cells_mixed = 0
	tgt_candidates_first_rung = 0
	tgt_candidates_deep_rungs = 0
	tgt_usec_first_rung = 0
	tgt_usec_deep_rungs = 0
	tgt_us_retained = 0
	tgt_us_proof = 0
	tgt_us_improve = 0
	tgt_us_focus = 0
	tgt_empty_to_focus = 0
	tgt_empty_to_formation_focus = 0
	tgt_empty_to_side_focus = 0
	tgt_search_cells_samples = PackedInt32Array()
	tgt_search_cand_samples = PackedInt32Array()
	tgt_search_result_dist = PackedFloat32Array()
	tgt_samples_capped = false
	foc_passes = 0
	foc_evaluations = 0
	foc_scans_from_formations = 0
	foc_scans_from_soldiers = 0
	foc_scans_direct = 0
	foc_global_scans = 0
	foc_units_examined = 0
	foc_units_from_formations = 0
	foc_units_from_soldiers = 0
	foc_buckets_measured = 0
	foc_buckets_opened = 0
	foc_members_walked = 0
	foc_target_calls = 0
	foc_formation_hits = 0
	foc_formation_repairs = 0
	foc_side_uses = 0
	foc_side_repairs = 0
	foc_side_centre_reads = 0
	foc_changes = 0
	foc_allocations = 0
	foc_scans_worst_tick = 0
	foc_units_worst_tick = 0
	foc_changes_worst_tick = 0
	_foc_scans_this_tick = 0
	_foc_units_this_tick = 0
	_foc_changes_this_tick = 0
	_ensure_focus_arrays()


## ---------- development-only spike analysis --------------------------------

## The phase clocks as they stand, for the tick that is about to run to subtract from.
func _sample_mark() -> Dictionary:
	return {
		"total": float(profile.get("total", 0.0)),
		"grid": float(profile.get("grid", 0.0)),
		"focus": float(profile.get("focus", 0.0)),
		"formation": float(profile.get("formation", 0.0)),
		"soldiers": float(profile.get("soldiers", 0.0)),
		"target": float(profile.get("target", 0.0)),
		"overlap": float(profile.get("overlap", 0.0)),
		# Step 7.8. The native pass's own decomposition, sampled like the rest: a kernel that
		# is fast on average and occasionally slow at the boundary is a stutter, and an
		# average is exactly the figure that hides it.
		"overlap_sync": float(profile.get("overlap_sync", 0.0)),
		"overlap_native": float(profile.get("overlap_native", 0.0)),
		"overlap_apply": float(profile.get("overlap_apply", 0.0)),
	}


## Record one tick's own cost for each phase. The distributions this builds are what
## catch a system that averages well and spikes - which a staggered cadence is exactly
## the sort of change that can cause. See D-084.
##
## Plain arrays rather than packed ones because a packed array in this engine is copied
## when it is read back out of a dictionary, which would turn a run of samples into a
## quadratic one for no benefit. The samples are a few thousand floats and they are read
## once, at the end, by a report.
func _sample_tick(mark: Dictionary) -> void:
	for key in mark.keys():
		var series: Array = samples.get(key, [])
		series.append(float(profile.get(key, 0.0)) - float(mark[key]))
		samples[key] = series


## Average and tail of one sampled phase, in milliseconds per tick. p50/p95/p99 are
## nearest-rank on the sorted samples, which is honest for the sizes measured here and
## says so rather than pretending to interpolate.
func phase_stats(key: String) -> Dictionary:
	var series: Array = samples.get(key, [])
	if series.is_empty():
		return {}
	var sorted := series.duplicate()
	sorted.sort()
	var total := 0.0
	for value in series:
		total += value
	return {
		"count": sorted.size(),
		"avg": total / float(sorted.size()),
		"p50": _percentile(sorted, 0.50),
		"p95": _percentile(sorted, 0.95),
		"p99": _percentile(sorted, 0.99),
		"max": sorted[sorted.size() - 1],
	}


## Nearest-rank percentile of an already sorted array, clamped into range.
func _percentile(sorted: Array, fraction: float) -> float:
	var position := clampi(int(ceil(fraction * float(sorted.size()))) - 1, 0, sorted.size() - 1)
	return float(sorted[position])


## ---------- development-only target report --------------------------------

## Everything target handling counted since the last reset, with the derived figures the
## milestone is judged on. Development-only data; nothing in the game reads it.
##
## The derived numbers are the point of the report rather than the raw counters: searches
## per soldier per simulated second says whether the cadence is doing what it claims,
## "searches avoided" says how much of the old every-tick behaviour is gone, and the
## switch count per thousand soldiers per second is the churn figure that has to stay
## small for the persistence rule to be a good one rather than merely a cheap one.
func target_report() -> Dictionary:
	var ticks := maxi(1, int(profile.get("ticks", 0)))
	var soldier_ticks := maxi(1, tgt_soldier_ticks)
	var simulated_seconds := float(ticks) * _tick_seconds()
	var report := {
		"ticks": ticks,
		"soldier_ticks": tgt_soldier_ticks,
		"searches": tgt_searches,
		"searches_per_tick": float(tgt_searches) / float(ticks),
		"successful_searches": tgt_successful_searches,
		"empty_searches": tgt_empty_searches,
		"retained_in_reach": tgt_retained_in_reach,
		"retained_held": tgt_retained_held,
		"retained_uses": tgt_retained_in_reach + tgt_retained_held,
		"searches_avoided": maxi(0, tgt_soldier_ticks - tgt_searches),
		"searches_avoided_pct": 100.0 * float(maxi(0, tgt_soldier_ticks - tgt_searches)) / float(soldier_ticks),
		"searches_per_soldier_second": float(tgt_searches) / maxf(0.0001, float(tgt_soldier_ticks) * _tick_seconds()),
		"focus_fallbacks": tgt_focus_fallbacks,
		"focus_per_tick": float(tgt_focus_fallbacks) / float(ticks),
		"focus_proven": tgt_focus_proven,
		"focus_proven_pct": 100.0 * float(tgt_focus_proven) / maxf(1.0, float(tgt_focus_fallbacks)),
		"explicit_order_uses": tgt_explicit_order_uses,
		"order_clears": tgt_order_clears,
		# The formation-driven layer (D-105). Named apart from the retention counters above,
		# because "searches_avoided" already means something else in this report: looks the
		# retention rule made unnecessary. These are looks the [i]hierarchy[/i] refused.
		"formation_enabled": engagement_enabled,
		"formation_deferrals": fdr_searches_avoided,
		"formation_gate_allowed": fdr_searches_allowed,
		"formation_promoted": fdr_promoted_soldiers,
		"formation_promotions": fdr_promotions,
		"formation_demotions": fdr_demotions,
		"formation_retaliations": fdr_retaliations,
		"formation_bodies_targeted": fdr_bodies_targeted,
		"formation_bodies_engaged": fdr_bodies_engaged,
		"invalid_dead": tgt_invalid_dead,
		"invalid_far": tgt_invalid_far,
		"invalid_gone": tgt_invalid_gone,
		"invalid_side": tgt_invalid_side,
		"invalidations": tgt_invalid_dead + tgt_invalid_far + tgt_invalid_gone + tgt_invalid_side,
		"invalidations_per_tick": float(tgt_invalid_dead + tgt_invalid_far + tgt_invalid_gone + tgt_invalid_side) / float(ticks),
		"immediate_reacquires": tgt_immediate_reacquires,
		"scheduled_reacquires": tgt_scheduled_reacquires,
		"candidates": tgt_candidates,
		"candidates_per_search": float(tgt_candidates) / maxf(1.0, float(tgt_searches)),
		"candidates_max": tgt_candidates_max,
		"acquisitions": tgt_acquisitions,
		"switches": tgt_switches,
		"latency_samples": tgt_latency_samples,
		"latency_avg_ticks": float(tgt_latency_ticks) / maxf(1.0, float(tgt_latency_samples)),
		"latency_worst_ticks": tgt_latency_worst,
		"latency_over_cadence": tgt_latency_over_cadence,
		"switches_per_1000_soldiers_second": 1000.0 * float(tgt_switches) / maxf(0.0001, float(soldier_ticks) * _tick_seconds()),
		"cadence_ticks": target_reacquisition_ticks,
		"retention_radius": target_retention_radius,
		"switch_advantage": target_switch_advantage,
		"immediate_on_contact_loss": target_immediate_on_contact_loss,
		"simulated_seconds": simulated_seconds,
	}
	var rungs: Array[int] = []
	for count in tgt_rung_hits:
		rungs.append(count)
	report["rung_hits"] = rungs
	report["search_shape"] = _search_shape_report()
	return report


## The shape of the searches a battle actually ran: how much ground each one walked, how
## many candidates it measured, where the answers were found, and how much of the cost was
## the widening rung rather than the first look.
##
## Development-only. The percentiles are exact rather than bucketed - one sample per search
## is cheap enough to keep, and a mean over a million cheap looks and a few thousand wide
## ones describes neither of them.
func _search_shape_report() -> Dictionary:
	var searches := maxf(1.0, float(tgt_searches))
	var cells_sorted := Array(tgt_search_cells_samples)
	cells_sorted.sort()
	var cand_sorted := Array(tgt_search_cand_samples)
	cand_sorted.sort()
	var dist_sorted := Array(tgt_search_result_dist)
	dist_sorted.sort()
	var cells := {
		"avg": float(tgt_cells_inspected) / searches,
		"p50": _percentile(cells_sorted, 0.50) if not cells_sorted.is_empty() else 0.0,
		"p95": _percentile(cells_sorted, 0.95) if not cells_sorted.is_empty() else 0.0,
		"p99": _percentile(cells_sorted, 0.99) if not cells_sorted.is_empty() else 0.0,
		"max": float(cells_sorted[cells_sorted.size() - 1]) if not cells_sorted.is_empty() else 0.0,
	}
	var candidates := {
		"avg": float(tgt_candidates_first_rung + tgt_candidates_deep_rungs) / searches,
		"p50": _percentile(cand_sorted, 0.50) if not cand_sorted.is_empty() else 0.0,
		"p95": _percentile(cand_sorted, 0.95) if not cand_sorted.is_empty() else 0.0,
		"p99": _percentile(cand_sorted, 0.99) if not cand_sorted.is_empty() else 0.0,
		"max": float(cand_sorted[cand_sorted.size() - 1]) if not cand_sorted.is_empty() else 0.0,
	}
	var reached := {
		"avg": float(tgt_search_result_dist.size()) / searches,
		"p50": _percentile(dist_sorted, 0.50) if not dist_sorted.is_empty() else 0.0,
		"p95": _percentile(dist_sorted, 0.95) if not dist_sorted.is_empty() else 0.0,
		"p99": _percentile(dist_sorted, 0.99) if not dist_sorted.is_empty() else 0.0,
		"max": float(dist_sorted[dist_sorted.size() - 1]) if not dist_sorted.is_empty() else 0.0,
	}
	return {
		"grid_queries": tgt_grid_queries,
		"grid_queries_per_search": float(tgt_grid_queries) / searches,
		"cells_inspected": tgt_cells_inspected,
		"cells_unique": tgt_cells_unique,
		"cells_repeated": tgt_cells_repeated,
		"cells_repeated_pct": 100.0 * float(tgt_cells_repeated) / maxf(1.0, float(tgt_cells_clean)),
		"searches_clean": tgt_searches_clean,
		"cells_clean": tgt_cells_clean,
		"cells_mixed": tgt_cells_mixed,
		"cells_clean_avg": float(tgt_cells_clean) / maxf(1.0, float(tgt_searches_clean)),
		"cells_unique_avg": float(tgt_cells_unique) / maxf(1.0, float(tgt_searches_clean)),
		"cells_repeated_avg": float(tgt_cells_repeated) / maxf(1.0, float(tgt_searches_clean)),
		"cells": cells,
		"candidates": candidates,
		"candidates_first_rung": tgt_candidates_first_rung,
		"candidates_deep_rungs": tgt_candidates_deep_rungs,
		"reached": reached,
		"searches_escalated": tgt_searches_escalated,
		"deep_hits": tgt_deep_hits,
		"searches_at_ceiling": tgt_searches_at_ceiling,
		"searches_mixed_walk": tgt_searches_mixed_walk,
		"empty_to_focus": tgt_empty_to_focus,
		"empty_to_formation_focus": tgt_empty_to_formation_focus,
		"empty_to_side_focus": tgt_empty_to_side_focus,
		"avg_usec_first_rung": float(tgt_usec_first_rung) / searches,
		"avg_usec_deep_rungs": float(tgt_usec_deep_rungs) / searches,
		"total_usec_grid": tgt_usec_first_rung + tgt_usec_deep_rungs,
		"usec_retained": tgt_us_retained,
		"usec_proof": tgt_us_proof,
		"usec_improve": tgt_us_improve,
		"usec_focus": tgt_us_focus,
		"samples": tgt_search_cells_samples.size(),
		"samples_capped": tgt_samples_capped,
		"search_radius": target_search_radius,
		"escalation": target_search_escalation,
		"ceiling": target_search_max_radius,
	}


## Everything the focus path counted since the last reset, with the derived figures the
## milestone is judged on. Development-only data; nothing in the game reads it.
##
## The headline figure is [code]scans_from_soldiers[/code]. It is the counter the brief asks
## for by name: how many whole-army scans the formation-focus logic performs on behalf of
## individual soldiers. Every one of them is a soldier doing work its formation has already
## done, and the target is zero. The per-tick and per-evaluation figures are what make the
## number actionable rather than merely small or large.
func focus_report() -> Dictionary:
	var ticks := maxi(1, int(profile.get("ticks", 0)))
	var evaluations := maxi(1, foc_evaluations)
	var report := {
		"ticks": ticks,
		"formations": formations.size(),
		"passes": foc_passes,
		"passes_per_tick": float(foc_passes) / float(ticks),
		"evaluations": foc_evaluations,
		"evaluations_per_tick": float(foc_evaluations) / float(ticks),
		"global_scans": foc_global_scans,
		"scans_per_tick": float(foc_global_scans) / float(ticks),
		"scans_from_formations": foc_scans_from_formations,
		"scans_from_soldiers": foc_scans_from_soldiers,
		"scans_direct": foc_scans_direct,
		"soldier_scans_per_tick": float(foc_scans_from_soldiers) / float(ticks),
		"units_examined": foc_units_examined,
		"units_per_tick": float(foc_units_examined) / float(ticks),
		"units_from_formations": foc_units_from_formations,
		"units_from_soldiers": foc_units_from_soldiers,
		"units_per_evaluation": float(foc_units_examined) / float(evaluations),
		"target_calls": foc_target_calls,
		"target_calls_per_tick": float(foc_target_calls) / float(ticks),
		"formation_hits": foc_formation_hits,
		"formation_repairs": foc_formation_repairs,
		"side_uses": foc_side_uses,
		"side_repairs": foc_side_repairs,
		"side_centre_reads": foc_side_centre_reads,
		"buckets_measured": foc_buckets_measured,
		"buckets_measured_per_evaluation": float(foc_buckets_measured) / float(evaluations),
		"buckets_opened": foc_buckets_opened,
		"buckets_opened_per_evaluation": float(foc_buckets_opened) / float(evaluations),
		"members_walked": foc_members_walked,
		"members_per_opened": float(foc_members_walked) / maxf(1.0, float(foc_buckets_opened)),
		"changes": foc_changes,
		"changes_per_tick": float(foc_changes) / float(ticks),
		"allocations": foc_allocations,
		"scans_worst_tick": foc_scans_worst_tick,
		"units_worst_tick": foc_units_worst_tick,
		"changes_worst_tick": foc_changes_worst_tick,
	}
	return report


## One simulation tick in seconds, as the battle itself is being stepped with. The
## schedule counts ticks rather than seconds, so the only place seconds appear at all is
## this report, where a reader wants them.
func _tick_seconds() -> float:
	if config == null:
		return 0.05
	var rate := config.get_float("battle.tick_rate", 0.0)
	if rate <= 0.0:
		return 0.05
	return 1.0 / rate


## ---------- overlap instrumentation helpers --------------------------------

## Everything the separation pass counted last tick. Development-only data; nothing in
## the game reads it.
func overlap_report() -> Dictionary:
	return overlap_stats


func _update_unit(unit: BattleUnit, delta: float) -> void:
	unit.cooldown_left = maxf(0.0, unit.cooldown_left - delta)
	# Read the profile flag once per soldier rather than once per counter: eight member reads became
	# one local read, and the guards below test the local. An auditor asked for the off path to have no
	# per-soldier profiling cost it did not have before, and eight reads of a member is cost.
	var profiling := profile_enabled
	if profiling:
		tgt_soldier_ticks += 1
		upd_calls += 1

	# An explicit attack order is a player instruction, so it is resolved [i]before[/i]
	# the automatic search rather than after it. The order is authoritative whenever it
	# is valid, which is most ticks of most ordered soldiers, so asking the battlefield
	# for the nearest enemy and then discarding the answer is work done to be thrown
	# away - and on a five-thousand-soldier field that work is not free. The semantics
	# are identical either way: the order is honoured while its target is a living enemy
	# and lapses the moment it is not.
	#
	# Step 7.4 keeps this exactly where it was and in front of everything else: no
	# cadence, no retention and no measurement of who is nearest is allowed to introduce
	# a tick of latency into an order the player just gave. See D-085.
	var target: BattleUnit = null
	if unit.attack_order_target_id >= 0:
		var ordered := find_unit(unit.attack_order_target_id)
		if ordered != null and ordered.is_alive() and ordered.side != unit.side:
			target = ordered
			if profiling:
				tgt_explicit_order_uses += 1
		else:
			unit.attack_order_target_id = -1
			if profiling:
				tgt_order_clears += 1

	if target == null:
		var target_probe := 0
		if profiling:
			target_probe = Time.get_ticks_usec()
		target = _resolve_target(unit)
		if target_probe > 0:
			_profile_accumulate("target", target_probe)

	if target == null:
		# Nobody worth keeping and nobody found - and this soldier has just been struck. Strike
		# back at whoever struck it: the attacker's id was recorded by the damage step, so this
		# costs one index probe and no search. It is what keeps a rank taken in the flank or the
		# rear from standing still, and it is deliberately [i]after[/i] the ordinary resolution:
		# a soldier already fighting somebody does not drop that fight because a second enemy
		# clipped it, which is what stops a melee soldier thrashing between attackers. See D-105.
		target = _retaliation_target(unit)
	if target == null:
		return
	if profiling:
		upd_targeted += 1

	unit.facing = (target.position - unit.position).normalized()

	if unit.position.distance_to(target.position) <= unit.attack_range:
		if profiling:
			upd_in_reach += 1
		# In reach: stand and strike rather than walk into the enemy. This is also the
		# only place that decides what "in contact" means, which is why the flag is set
		# here rather than being recomputed later by someone else. It is set on the
		# soldier's own body: contact is a fact about the formation that is fighting,
		# not about its side of the field.
		if unit.formation_ref != null:
			unit.formation_ref.mark_in_contact()
		if unit.cooldown_left <= 0.0:
			_attack(unit, target)
		return

	# A formed soldier holds its place in the body. It does not pick its own ground and
	# does not run off after a target: the formation decides where the body is, and this
	# soldier's job is to be where it was put. That is what keeps a line a line - and it
	# is also why a large battle stays affordable, because most soldiers are doing
	# arithmetic rather than deciding anything.
	if unit.is_formed():
		var body := unit.formation_ref
		if profiling:
			upd_formed += 1
		# Pressing forward is the one exception, and it is deliberately narrow. A body
		# that has stopped, has been told to engage, and has nobody on its side
		# fighting has no line left to hold: the fighting has stopped happening, and
		# the nearest men crossing the gap is what starts it again. While anyone on
		# this side is in contact the dressing wins, which is what stops a battle
		# dissolving into a crowd.
		if _can_press_forward(unit, body):
			if profiling:
				upd_pressed_forward += 1
			_move_toward(unit, target.position, delta)
			return
		var place := unit.formation_slot()
		if profiling:
			upd_slot_lookups += 1
		# A soldier standing in his place goes where his body goes. The body worked that step out
		# once, for the whole group, at the top of the tick; making four hundred men each derive the
		# same displacement - a slot lookup, a distance, a normalise and a terrain lookup apiece -
		# is the group's arithmetic done four hundred times. Anyone out of his place, and every body
		# that is turning, reforming or standing still, dresses himself exactly as before.
		# See D-108.
		if rigid_groups_enabled and body.anchor_step != Vector2.ZERO \
				and unit.position.distance_squared_to(place) <= ARRIVE_EPSILON * ARRIVE_EPSILON:
			if profiling:
				upd_rigid_steps += 1
			_step_with_body(unit, body.anchor_step)
			return
		if unit.position.distance_to(place) > ARRIVE_EPSILON:
			_move_toward(unit, place, delta)
		return

	if unit.has_move_order:
		if profiling:
			upd_move_orders += 1
		_move_toward(unit, unit.move_order, delta)
		if unit.position.distance_to(unit.move_order) <= 1.0:
			unit.clear_orders()
		return

	_move_toward(unit, target.position, delta)


func _attack(attacker: BattleUnit, target: BattleUnit) -> void:
	# A target chosen this step can already have been struck down by someone else
	# earlier in the same step. Hitting a corpse would credit a kill twice.
	if not target.is_alive():
		return
	attacker.cooldown_left = attacker.attack_cooldown

	if rng.randf() > base_hit_chance:
		events.append({
			"type": "miss",
			"attacker": attacker.id,
			"target": target.id,
			"position": target.position,
		})
		return

	var raw := float(attacker.attack) * rng.randf_range(0.85, 1.15)
	var reduction := minf(0.7, float(target.defence) * defence_mitigation)
	var damage := maxi(1, int(round(raw * (1.0 - reduction))))

	var killed := target.take_damage(damage, attacker.id)
	attacker.damage_dealt += damage
	# Who struck whom, for the formation-driven layer: a soldier that has just been hit may
	# strike back at its attacker without being allowed to search for anybody. Recorded only on
	# a hit, because a hit is the unambiguous statement that somebody is fighting this soldier.
	# See D-105.
	target.last_attacker_id = attacker.id
	target.last_attacked_tick = tick_index
	if killed and grid != null:
		# One of the battle's two live-state mutation points. The other is movement, in
		# _move_toward. COMPARE_FULL is what proves the pair is complete. See D-095.
		grid.native_died(target)

	events.append({
		"type": "hit",
		"attacker": attacker.id,
		"target": target.id,
		"damage": damage,
		"position": target.position,
		"ranged": attacker.ranged,
		"killed": killed,
	})

	if killed:
		attacker.kills += 1
		_living_total = maxi(0, _living_total - 1)
		if target.fdr_promoted:
			# A promoted soldier who dies stops being one, which is what keeps the running
			# total of individual-aware soldiers exact without a recount.
			target.fdr_promoted = false
			fdr_promoted_soldiers = maxi(0, fdr_promoted_soldiers - 1)
		events.append({
			"type": "death",
			"unit": target.id,
			"unit_name": target.display_name,
			"side": target.side,
			"soldier_id": target.soldier_id,
			"killer": attacker.id,
			"killer_name": attacker.display_name,
			"killer_side": attacker.side,
			"position": target.position,
		})
		# Anyone hunting this unit must pick a new quarry.
		#
		# The hunters are in the order index, chained onto this soldier when the tick's chains were
		# built, so this clears exactly the men who were hunting him and inspects nobody else. The two
		# paths - instrumented and not - are separate loops on purpose: a battle that is not being
		# measured must pay no counter test at all. Rebuilt here if it is not the current tick's
		# index, because the probe and the suites call this directly rather than through a step.
		if _order_index_tick != tick_index:
			_rebuild_order_index()
		if profile_enabled:
			var cleanup_mark := Time.get_ticks_usec()
			var inspected := 0
			var cleared := 0
			var hunter := _order_head[target.id] if target.id < _order_head.size() else -1
			while hunter >= 0:
				inspected += 1
				var hound: BattleUnit = find_unit(hunter)
				if hound != null and hound.attack_order_target_id == target.id:
					hound.attack_order_target_id = -1
					cleared += 1
				hunter = _order_next[hunter]
			kill_cleanup_deaths += 1
			kill_cleanup_inspections += inspected
			kill_cleanup_clears += cleared
			kill_cleanup_worst_inspections = maxi(kill_cleanup_worst_inspections, inspected)
			kill_cleanup_usec += Time.get_ticks_usec() - cleanup_mark
		else:
			var hunter := _order_head[target.id] if target.id < _order_head.size() else -1
			while hunter >= 0:
				var hound: BattleUnit = find_unit(hunter)
				if hound != null and hound.attack_order_target_id == target.id:
					hound.attack_order_target_id = -1
				hunter = _order_next[hunter]


## ---------- target acquisition (Step 7.4) ---------------------------------

## Who this soldier is dealing with this tick.
##
## [b]The order of the questions is the design.[/b] Everything cheap is asked before
## anything expensive, and the expensive question - a spatial search - is only reached
## when the cheaper ones have said it is worth asking:
##
## [codeblock]
## explicit order?          use it                       (player instruction, no search)
## remembered opponent?
##     in reach?            use it                       (no search: the fastest path)
##     not this soldier's turn yet?
##                          use it                       (no search: still relevant)
## turned to look?
##     search: nearest local enemy, or the formation's focus
## [/codeblock]
##
## A soldier that is out of reach and not due to look falls to the formation's or its
## side's focus, which is the answer the bodies have already worked out for themselves
## once this tick - the architecture that exists precisely so a soldier far from the
## fighting does not have to ask the battlefield a question every tick. See D-080, D-085.
func _resolve_target(unit: BattleUnit) -> BattleUnit:
	_search_is_immediate = false
	var retained_mark := Time.get_ticks_usec() if profile_enabled and target_timing_enabled else 0
	var retained := _retained_target(unit)
	if profile_enabled and target_timing_enabled:
		tgt_us_retained += Time.get_ticks_usec() - retained_mark
	if retained != null:
		var reach := unit.attack_range
		if unit.position.distance_squared_to(retained.position) <= reach * reach:
			if profile_enabled:
				tgt_retained_in_reach += 1
			return retained
		if tick_index < unit.next_search_tick:
			if profile_enabled:
				tgt_retained_held += 1
			return retained
	elif tick_index < unit.next_search_tick:
		# Nothing remembered, and it is not this soldier's turn to look. The cheap
		# answer is the one its body already has.
		var cheap_mark := Time.get_ticks_usec() if profile_enabled and target_timing_enabled else 0
		var cheap := _focus_target(unit)
		if profile_enabled:
			tgt_focus_fallbacks += 1
			tgt_us_focus += Time.get_ticks_usec() - cheap_mark
		return cheap
	# The soldier's awareness has come round and it would look for an opponent of its own. Ask
	# its body first: a soldier in a body that is marching, dressing or holding has no fight of
	# its own to look for, and the battlefield is not asked on its behalf. See D-105.
	var allowed := _formation_driven_search_allowed(unit)
	_note_search_decision(unit, allowed)
	if not allowed:
		# Formation-driven. Keep the opponent this soldier already had - a fight in progress is
		# not interrupted by a change of formation geometry - and otherwise take the answer the
		# body has, which is the enemy it is marching towards. The search is deferred, not
		# cancelled: the next awareness tick asks again, and the band will have moved by then.
		unit.next_search_tick = tick_index + target_reacquisition_ticks
		if retained != null:
			return retained
		return _focus_target(unit)
	return _search_for_target(unit, retained)


## The enemy this soldier was already dealing with, if it is still worth dealing with.
##
## Cheap by construction: one index probe and a handful of comparisons, with no spatial
## query anywhere in it. That is what makes retaining an opponent cheaper than finding
## one, by orders of magnitude, and it is the whole reason the milestone works.
##
## [b]It is also where a loss is noticed[/b], and it is the only place in the milestone
## that can bring a search forward off the cadence. An opponent that died while the
## soldier could have struck it is a fight in progress, and making that soldier wait for
## its slot would leave it standing over a corpse. An opponent that simply got too far
## away, or that was never in reach to begin with, waits for its slot like everything
## else: nothing was taken away from that soldier mid-swing. See D-083.
func _retained_target(unit: BattleUnit) -> BattleUnit:
	if unit.auto_target_id < 0:
		return null
	var cached: BattleUnit = _unit_by_id.get(unit.auto_target_id)
	if cached == null:
		unit.auto_target_id = -1
		if profile_enabled:
			tgt_invalid_gone += 1
		return null
	if cached.side == unit.side:
		# Not reachable today - the search only ever returns enemies - but a remembered
		# answer that has become an ally is exactly the sort of thing an optimisation
		# should refuse rather than attack.
		unit.auto_target_id = -1
		if profile_enabled:
			tgt_invalid_side += 1
		return null
	if not cached.is_alive():
		var lost_reach := unit.attack_range * target_contact_loss_factor
		var fought_it := unit.position.distance_squared_to(cached.position) <= lost_reach * lost_reach
		unit.auto_target_id = -1
		if profile_enabled:
			tgt_invalid_dead += 1
			unit.target_lost_tick = tick_index
		if fought_it and target_immediate_on_contact_loss:
			unit.next_search_tick = tick_index
			_search_is_immediate = true
		return null
	var retention := _retention_radius_of(unit)
	if unit.position.distance_squared_to(cached.position) > retention * retention:
		unit.auto_target_id = -1
		if profile_enabled:
			tgt_invalid_far += 1
			unit.target_lost_tick = tick_index
		return null
	return cached


## Look around, and take the answer. Called only when a soldier has nobody worth
## continuing with, or when its own awareness tick has come round.
##
## The remembered opponent is not discarded merely because a search happened. It is
## discarded when a better answer exists, and "better" has to be better by
## [member target_switch_advantage] rather than by a hair, which is the hysteresis that
## stops two similar enemies exchanging the answer on alternate ticks and walking a
## soldier in circles. See D-081.
func _search_for_target(unit: BattleUnit, retained: BattleUnit) -> BattleUnit:
	# The cheapest look of all is the one that is not worth making. A soldier whose body's
	# nearest enemy is further away than this soldier could see cannot find anybody by
	# looking, so it is pointed at the fighting instead and the battlefield is not asked.
	var proof_mark := Time.get_ticks_usec() if profile_enabled and target_timing_enabled else 0
	var nothing_to_find := _focus_look_finds_nobody(unit)
	if profile_enabled and target_timing_enabled:
		tgt_us_proof += Time.get_ticks_usec() - proof_mark
	if nothing_to_find:
		if profile_enabled:
			tgt_focus_fallbacks += 1
			tgt_focus_proven += 1
		unit.next_search_tick = tick_index + target_reacquisition_ticks
		if retained != null:
			return retained
		unit.auto_target_id = -1
		return _focus_target(unit)

	if profile_enabled:
		tgt_searches += 1
		if _search_is_immediate:
			tgt_immediate_reacquires += 1
		else:
			tgt_scheduled_reacquires += 1

	var local := _nearest_local_enemy(unit)
	if local != null:
		var improve_mark := Time.get_ticks_usec() if profile_enabled and target_timing_enabled else 0
		if retained != null and not _clear_improvement(unit, retained, local):
			local = retained
		_store_target(unit, local)
		if profile_enabled and target_timing_enabled:
			tgt_us_improve += Time.get_ticks_usec() - improve_mark
		if profile_enabled:
			tgt_successful_searches += 1
		return local

	if profile_enabled:
		tgt_empty_searches += 1
	unit.next_search_tick = tick_index + target_reacquisition_ticks
	if retained != null:
		# Nobody local, but the opponent this soldier already had is still valid: it is
		# simply standing further off than the search reaches. Keeping it is the point of
		# a retention radius wider than the search radius.
		return retained
	# Nobody found and nobody remembered: this soldier is pointed at the fighting. It is
	# counted as a search rather than as a focus fallback, because this tick did pay for
	# a search - the two counters partition soldier-ticks between them, and a tick that
	# looked is a tick that looked, whatever it found.
	unit.auto_target_id = -1
	var focus_mark := Time.get_ticks_usec() if profile_enabled else 0
	var pointed := _focus_target(unit)
	if profile_enabled:
		tgt_us_focus += Time.get_ticks_usec() - focus_mark
		# Which layer answered the soldier that found nobody. Both are formation-level
		# awareness; the split says whether a body's own focus was enough or whether the
		# side had to be asked, which is the difference between the hierarchy working and
		# it being bypassed by a loose soldier.
		tgt_empty_to_focus += 1
		if unit.formation_ref != null and _focus_unit_of(unit.formation_ref) == pointed:
			tgt_empty_to_formation_focus += 1
		else:
			tgt_empty_to_side_focus += 1
	return pointed


## Whether a freshly found enemy is enough of an improvement to be worth abandoning the
## opponent this soldier is already dealing with.
##
## Deliberately generous to the incumbent. A soldier holding an opponent it can reach
## should not swap to one that is a hundredth of a unit closer, because that is not a
## better fight - it is the same fight with extra turning.
func _clear_improvement(unit: BattleUnit, retained: BattleUnit, candidate: BattleUnit) -> bool:
	if retained == candidate:
		return true
	# Compared squared, so the advantage is squared with it rather than rooted out per
	# candidate. Same answer, one fewer square root in a hot loop.
	var advantage := target_switch_advantage * target_switch_advantage
	var held := unit.position.distance_squared_to(retained.position)
	var fresh := unit.position.distance_squared_to(candidate.position)
	return fresh * advantage < held


## Remember an opponent and put this soldier's next look a cadence away.
func _store_target(unit: BattleUnit, chosen: BattleUnit) -> void:
	if profile_enabled:
		var previous := unit.auto_target_id
		if previous >= 0 and chosen != null and chosen.id != previous:
			tgt_switches += 1
		elif previous < 0 and chosen != null:
			tgt_acquisitions += 1
			if unit.target_lost_tick >= 0:
				var waited := tick_index - unit.target_lost_tick
				tgt_latency_ticks += waited
				tgt_latency_worst = maxi(tgt_latency_worst, waited)
				tgt_latency_samples += 1
				if waited > target_reacquisition_ticks:
					tgt_latency_over_cadence += 1
				unit.target_lost_tick = -1
	unit.auto_target_id = chosen.id if chosen != null else -1
	unit.next_search_tick = tick_index + target_reacquisition_ticks


## How far this soldier looks when it searches. Config for every unit that does not say
## otherwise; a unit that carries its own awareness radius uses that.
##
## The point of the override is that nothing here assumes a one-point-eight-unit reach.
## A soldier that one day carries a bow needs a wider look, and it says so on itself
## rather than the query being rewritten around a weapon name. There are no archers in
## this milestone and this changes no behaviour on its own. See D-086.
func _search_radius_of(unit: BattleUnit) -> float:
	return unit.awareness_radius if unit.awareness_radius > 0.0 else target_search_radius


## The widest rung of this soldier's ladder. Never below its own starting radius, so a
## ladder always has at least one rung and always terminates.
func _search_ceiling_of(unit: BattleUnit) -> float:
	return maxf(_search_radius_of(unit), target_search_max_radius)


## How far a remembered opponent may be before continuing with it stops being reasonable.
## Never tighter than the radius the soldier searches at, or a soldier would drop the
## enemy it holds only to find it again on the next look.
func _retention_radius_of(unit: BattleUnit) -> float:
	return maxf(_search_radius_of(unit), target_retention_radius)


## Whether a look by this soldier would provably find nobody, in which case the battlefield
## is not asked at all.
##
## [b]The proof.[/b] A body's focus is the enemy nearest to that body's anchor, at a known
## distance. This soldier stands a known distance from the same anchor. For any enemy E,
## [code]d(soldier, E) >= d(anchor, E) - d(soldier, anchor) >= focus_distance - offset[/code],
## so when that bound is already beyond the widest rung of this soldier's ladder there is no
## enemy the ladder could have returned: every candidate it would have measured is further
## away than it may look. The grid's own query margin is subtracted because both the focus
## and the soldier may have moved since the focus was computed, by at most the distance the
## fastest soldier can walk in one tick.
##
## It is a proof rather than a heuristic, in the same spirit as the separation pass skipping
## the settled interior of a body (D-076). When the bound does not hold, the search runs
## exactly as it always did, so the answer is the same either way - what changes is whether
## a question with a known answer was worth asking. A test drives a live battle and asserts
## that every skipped look would indeed have found nobody. See D-087.
func _focus_look_finds_nobody(unit: BattleUnit) -> bool:
	if unit.formation_ref == null:
		return false
	var body := unit.formation_ref
	# A body whose focus predates a membership change has no distance to reason from, and
	# neither does one the battlefield does not address. Both mean the same thing here.
	if body.index < 0 or not body.is_focus_current():
		return false
	var reachable: float = body.focus_distance
	if reachable == INF:
		# Nobody on the other side at all: nothing to find and nothing to be pointed at.
		return true
	var margin := grid.query_margin if grid != null else 0.0
	var bound := reachable - unit.position.distance_to(body.anchor) - margin
	return bound > _search_ceiling_of(unit)


## The nearest living enemy inside this soldier's own awareness bound, or null when there
## is nobody local: a ladder of box queries outward from the soldier, stopping at the first
## radius that holds anybody.
##
## [b]Unchanged by Step 7.6, on measurement.[/b] That milestone set out to make this cheaper
## and finished by leaving it alone: five exact re-implementations were written and every one
## of them measured slower than this - a ring walk, an outward row walk, a row walk with an
## exact reach, a rectangle walk with a cell-level bound, and a walk over a coarse block index
## built for the purpose. The reason is in the interpreter rather than in the algorithms: a
## bound test costs about 0.3 us and the empty cell it skips costs about 0.12 us to open and
## dismiss, so pruning inside the loop loses to walking the rectangle. The ladder is cheap
## because its first rung is small and answers most looks before the second rung is reached.
## Its counters and the search-shape report below are what that conclusion rests on; the
## micro-benchmark that measured the alternatives is scripts/dev/search_bench.gd and the
## numbers are in D-094.
## Searched outward from the soldier rather than across the battlefield: a radius that
## comfortably exceeds anything anyone can currently reach, widening geometrically, and
## stopping the moment it finds anything at all. Because the search stops at the first
## radius that contains an enemy, the nearest enemy inside that radius [i]is[/i] the
## nearest enemy full stop - so this returns exactly what a scan of the whole field
## would have returned, for a cost that depends on how crowded the soldier's own
## neighbourhood is rather than on how large the army is. A test proves that equivalence
## directly, against a brute-force reference, over generated layouts. See D-061.
##
## The radius comes from config and is deliberately not tied to melee reach. The
## escalation ladder is what will let archers, long spears and cavalry threat detection
## search further without this method being rewritten - and widening a ladder is a
## config change, not a code change. Step 7.2 adds no such system.
func _nearest_local_enemy(unit: BattleUnit) -> BattleUnit:
	var enemy_side := enemy_side_of(unit.side)
	var ceiling := _search_ceiling_of(unit)
	var radius := _search_radius_of(unit)
	var rung := 0
	# Step 7.6. One ladder's shape, accumulated per rung so that the first look and the
	# widening can be told apart rather than averaged together. Every one of these is behind
	# the profile flag, and the collection happens once per rung rather than once per cell.
	var cells_here := 0
	var union_span := 0
	var candidates_first := 0
	var candidates_deep := 0
	var usec_first := 0
	var usec_deep := 0
	var mixed_walk := false
	var best: BattleUnit = null
	while true:
		rung += 1
		var occupied_before := grid.dev_occupied_walks if profile_enabled else 0
		var query_start := Time.get_ticks_usec() if profile_enabled else 0
		best = _nearest_enemy_within(unit, enemy_side, radius)
		if profile_enabled:
			var spent := Time.get_ticks_usec() - query_start
			if rung == 1:
				candidates_first = _query_scratch.size()
				usec_first = spent
			else:
				candidates_deep += _query_scratch.size()
				usec_deep += spent
			cells_here += grid.dev_last_read
			union_span = grid.dev_last_span
			if grid.dev_occupied_walks != occupied_before:
				mixed_walk = true
			if tgt_rung_hits.size() < rung:
				tgt_rung_hits.resize(rung)
			tgt_rung_hits[rung - 1] += 1
		if best != null:
			break
		var widened := minf(ceiling, radius * target_search_escalation)
		# Two ways out, and both are needed: the ladder is done when it has reached its
		# ceiling, and it is stuck when widening cannot widen any further. A ladder that
		# cannot terminate is a per-soldier scan of the whole battlefield by another name.
		if radius >= ceiling or widened <= radius:
			break
		radius = widened
	if profile_enabled:
		_record_search_shape(unit, best, rung, radius, ceiling, cells_here, union_span, candidates_first, candidates_deep, usec_first, usec_deep, mixed_walk)
	return best


## Record one ladder's shape. Called once per search, and only while profiling.
##
## The samples are appended rather than accumulated into a mean because the phase's shape is
## the thing being investigated: a mean over a million cheap looks and a few thousand wide
## ones describes neither, and the percentile is what says whether the widening is a rare
## cost or the common case.
func _record_search_shape(unit: BattleUnit, best: BattleUnit, rungs: int, last_radius: float, ceiling: float, cells: int, union_span: int, cand_first: int, cand_deep: int, usec_first: int, usec_deep: int, mixed_walk: bool) -> void:
	tgt_grid_queries += rungs
	tgt_cells_inspected += cells
	if mixed_walk:
		# A rung that walked the occupied list read only the cells that hold somebody, so
		# the widest box is not the union of what the search read and the difference is not
		# a repeat. Those searches are counted apart rather than folded in, because a
		# repeated-cell figure that silently includes them would be wrong in the direction
		# that flatters the milestone.
		tgt_searches_mixed_walk += 1
		tgt_cells_mixed += cells
	else:
		tgt_searches_clean += 1
		tgt_cells_clean += cells
		tgt_cells_unique += union_span
		tgt_cells_repeated += maxi(0, cells - union_span)
	tgt_candidates_first_rung += cand_first
	tgt_candidates_deep_rungs += cand_deep
	tgt_usec_first_rung += usec_first
	tgt_usec_deep_rungs += usec_deep
	if rungs > 1:
		tgt_searches_escalated += 1
		if best != null:
			tgt_deep_hits += 1
	if is_equal_approx(last_radius, ceiling):
		tgt_searches_at_ceiling += 1
	if tgt_search_cells_samples.size() >= TGT_SAMPLE_CAP or tgt_search_cand_samples.size() >= TGT_SAMPLE_CAP:
		tgt_samples_capped = true
	else:
		tgt_search_cells_samples.append(cells)
		tgt_search_cand_samples.append(cand_first + cand_deep)
		if best != null:
			tgt_search_result_dist.append(unit.position.distance_to(best.position))


## The nearest living enemy inside this soldier's own awareness bound, or null when there
## is nobody local.
##
## [b]One query, not a ladder.[/b] A ladder of radii computes the nearest enemy inside its
## widest rung - the first rung that holds anybody contains the nearest, which is what makes
## the old answer correct - and the grid can now be asked that question directly, once, with
## each cell opened at most once and the walk stopping as soon as no unopened cell could hold
## a better answer. Same answer, asked once. See D-094.
## The nearest living enemy to this soldier, or the enemy its body is pointed at when
## there is nobody within its own bound. This is the whole of the local search, and it is
## unchanged by Step 7.4: the milestone changed how often it is asked, never what it
## answers.
func _choose_target(unit: BattleUnit) -> BattleUnit:
	var best := _nearest_local_enemy(unit)
	if best != null:
		return best
	return _focus_target(unit)


## Size the focus path's per-side buffers for the roster the battle has. Called when the army
## is handed over, and again from the summary pass if the roster has grown since - a battle
## that adds soldiers after `add_units` should be described correctly rather than indexed out
## of bounds. A soldier is in its body's summary or in its side's loose run and never both, so
## one array per side is always more than enough, and sizing them here rather than growing them
## as they fill is what keeps a tick from allocating (D-091).
func _prepare_focus_buffers() -> void:
	var loose_player: Array[BattleUnit] = []
	var loose_enemy: Array[BattleUnit] = []
	loose_player.resize(units.size())
	loose_enemy.resize(units.size())
	_loose_units = [loose_player, loose_enemy]
	_loose_count = PackedInt32Array([0, 0])
	var highest := -1
	for unit in units:
		highest = maxi(highest, unit.id)
	_unit_slots = []
	_unit_slots.resize(highest + 1)
	for unit in units:
		if unit.id >= 0:
			_unit_slots[unit.id] = unit


## Rebuild every body's transient battlefield summary, and the per-side totals that go with
## it.
##
## [b]Two passes, and the order is the point.[/b] The first counts each body's own roll: the
## list of soldiers a body holds is the authority on who is in it, so the summary is derived
## from it rather than from each soldier's back-reference. A soldier detached through
## [method BattleFormation.remove_units] therefore stops being counted immediately, without
## the body having to know the soldier - which is the whole reason membership lives in a list
## of ids. The second pass walks the army once for the totals, and for the soldiers no body
## claimed: anyone who belongs to no body, and anyone whose body is not on their side, is
## counted as a loose soldier of their own side so that the focus layer can still find them.
## A soldier is counted exactly once, which is what the claim stamp on the soldier is for.
##
## [b]It is the only place in the focus path whose cost is proportional to the army, and it
## is proportional to it twice per tick rather than once per body per tick.[/b] Measured, the
## pass it replaced was 2,205,806 soldier-visits a tick at twenty thousand soldiers; this is
## 40,000 plus a body's worth per question (D-088).
##
## The summaries are rebuilt rather than updated. There is no delta to get wrong, no order the
## caller has to respect, and a body that was given soldiers or had them taken away since the
## last tick is described correctly by construction.
func _refresh_summaries() -> void:
	_ensure_focus_arrays()
	if _loose_units.size() < 2 or (_loose_units[0] as Array).size() < units.size():
		_prepare_focus_buffers()
	for i in 2:
		_loose_count[i] = 0
		_loose_sum[i] = Vector2.ZERO
		_side_sum[i] = Vector2.ZERO
		_side_living[i] = 0
	for formation in formations:
		formation.begin_summary()
		var ids := formation.unit_ids
		var bucket: Array[BattleUnit] = _body_members[formation.index]
		if bucket.size() < ids.size():
			bucket.resize(ids.size())
			if profile_enabled:
				foc_allocations += 1
		var keeping := 0
		var slots := _unit_slots.size()
		# The running total lives in locals rather than on the body: a Vector2 component
		# written onto an object is three property operations, and this loop runs once per
		# soldier per tick. See [method BattleFormation.write_summary].
		var sum := Vector2.ZERO
		var low := Vector2.ZERO
		var high := Vector2.ZERO
		var reach := 0.0
		for i in ids.size():
			var unit_id := ids[i]
			var unit: BattleUnit = _unit_slots[unit_id] if (unit_id >= 0 and unit_id < slots) else null
			if unit == null or not unit.is_alive() or unit.side != formation.side:
				continue
			var position := unit.position
			if keeping == 0:
				low = position
				high = position
			else:
				low.x = minf(low.x, position.x)
				low.y = minf(low.y, position.y)
				high.x = maxf(high.x, position.x)
				high.y = maxf(high.y, position.y)
			sum += position
			# The furthest reach in the body, for the contact band the formation-driven gate
			# measures against. One comparison per soldier in a pass that is already walking
			# them, so the band costs nothing to keep current. See D-105.
			if unit.attack_range > reach:
				reach = unit.attack_range
			unit.summary_tick = tick_index
			bucket[keeping] = unit
			keeping += 1
		_body_member_count[formation.index] = keeping
		formation.write_summary(keeping, sum, low, high, reach)
	_sides_built = false
	var claimed := 0
	for formation in formations:
		claimed += _body_member_count[formation.index]
	if claimed != _living_total:
		# Somebody is standing who belongs to no body, or to a body of the other side. Only
		# then is the army walked, because only then is there anything for that walk to find:
		# the side totals and the loose run exist for the soldier with no body to ask for it,
		# and a battle where every soldier is formed - which is a deployed army, and both
		# benchmark families - has none. See D-089.
		_walk_unclaimed()
		_sides_built = true
	_summary_tick = tick_index
	_build_buckets()


## The second half of the summary: the side totals, and the living soldiers no body claimed.
##
## Reached only when the count of soldiers a body counted does not match the number the
## battle believes are standing, which is the signal that there is somebody to collect. The
## running totals are locals for the same reason the body summaries are: a write into a
## [PackedInt32Array] or a typed array slot per soldier per tick was a measurable share of
## this pass.
func _walk_unclaimed() -> void:
	var sum_player := Vector2.ZERO
	var sum_enemy := Vector2.ZERO
	var alive_player := 0
	var alive_enemy := 0
	for unit in units:
		if not unit.is_alive():
			continue
		var index := _side_index(unit.side)
		var position := unit.position
		if index == 0:
			sum_player += position
			alive_player += 1
		else:
			sum_enemy += position
			alive_enemy += 1
		if unit.summary_tick == tick_index:
			continue
		var count := _loose_count[index]
		if count == 0:
			_loose_min[index] = position
			_loose_max[index] = position
		else:
			var low: Vector2 = _loose_min[index]
			var high: Vector2 = _loose_max[index]
			_loose_min[index] = Vector2(minf(low.x, position.x), minf(low.y, position.y))
			_loose_max[index] = Vector2(maxf(high.x, position.x), maxf(high.y, position.y))
		_loose_sum[index] += position
		_loose_units[index][count] = unit
		_loose_count[index] = count + 1
	_side_sum[0] = sum_player
	_side_sum[1] = sum_enemy
	_side_living[0] = alive_player
	_side_living[1] = alive_enemy


## The index a side is addressed by in the focus path's small per-side arrays. Two sides, two
## slots; anything that is not the player is treated as the enemy, which is what
## [method enemy_side_of] does with it as well.
func _side_index(side: String) -> int:
	return 0 if side == BattleContext.SIDE_PLAYER else 1


## Collect this tick's candidate enemy buckets, one run per side, into one shared buffer.
##
## A bucket is a place an enemy can be found: a body with somebody still standing in it, or
## a side's unformed soldiers. Two runs rather than one list because a body belongs to
## exactly one side and is only a candidate for the other - so each soldier is indexed once
## per tick and never twice.
func _build_buckets() -> void:
	var needed := formations.size() + 2
	if _bucket_codes.size() < needed:
		_bucket_codes.resize(needed)
		_bucket_taken.resize(needed)
		if profile_enabled:
			# The only allocation the focus path can make after the army was handed over,
			# and it happens once - when a body is added. Counted rather than described.
			foc_allocations += 2
	var cursor := 0
	for querying in 2:
		var owner := 1 - querying
		_bucket_start[querying] = cursor
		for i in formations.size():
			var formation := formations[i]
			if formation.is_living() and _side_index(formation.side) == owner:
				_bucket_codes[cursor] = i
				cursor += 1
		if _loose_count[owner] > 0:
			_bucket_codes[cursor] = -1 - owner
			cursor += 1
		_bucket_count[querying] = cursor - _bucket_start[querying]


## The living enemy nearest to [param point], or null when that side has nobody left.
##
## [b]Bodies first, soldiers second.[/b] Instead of walking the enemy army, this walks the
## enemy's [i]buckets[/i] and rules them out by their boxes: the distance from the point to a
## bucket's box is a lower bound on the distance to any soldier inside it, so a bucket whose
## box is already further away than the best soldier found cannot hold a nearer one and is
## not opened. Buckets are opened nearest-bound-first, so the answer is usually found in the
## first one or two and everything after them is dismissed by arithmetic on four numbers.
##
## [b]It is the same answer, not an approximation.[/b] The loop stops only when the closest
## remaining bound is beyond the best candidate found, which proves nothing left can beat it.
## What the bound buys is not a different answer but the right to stop early: a bucket that
## is dismissed is one whose every soldier is strictly further away than the one already in
## hand. A test drives live battles and compares the answer against the full scan of the
## army, body by body and tick by tick, rather than trusting the reasoning. See D-089.
##
## Ties go to the lower unit id, in this and in [method _nearest_enemy_to_point]: the rule is
## about the soldiers, not about the order they happened to be met in, which is what makes a
## focus decision reproducible whatever order a roster is assembled in.
func _nearest_enemy_via_buckets(side: String, point: Vector2) -> BattleUnit:
	# The selection is always answered from this tick's summaries. A caller that reaches it
	# before the tick's focus pass - the repair path when something asks very early, or a
	# test driving the simulator by hand - gets a correct answer rather than an empty
	# candidate list, and an empty candidate list is a body being told there is nobody on
	# the field. The check is one integer against the tick the summaries describe.
	if _summary_tick != tick_index:
		_refresh_summaries()
	var querying := _side_index(side)
	var run := _bucket_count[querying]
	_focus_last_bucket = -1
	if run == 0:
		return null
	var enemy_side := enemy_side_of(side)
	var start := _bucket_start[querying]
	_focus_query_id += 1
	var query := _focus_query_id
	var best: BattleUnit = null
	var best_distance := INF
	while true:
		# The unopened bucket whose box is nearest to the point. Ties go to the earliest
		# bucket in the run, which is the order the bodies were built in.
		var chosen := -1
		var chosen_bound := INF
		for k in run:
			var slot := start + k
			if _bucket_taken[slot] == query:
				continue
			if profile_enabled:
				foc_buckets_measured += 1
			var bound := _bucket_bound_squared(_bucket_codes[slot], point)
			if bound < chosen_bound:
				chosen_bound = bound
				chosen = slot
		if chosen < 0 or chosen_bound > best_distance:
			break
		_bucket_taken[chosen] = query
		var code := _bucket_codes[chosen]
		if profile_enabled:
			foc_buckets_opened += 1
		var found := _nearest_in_bucket(code, enemy_side, point)
		if found != null:
			var distance := point.distance_squared_to(found.position)
			if distance < best_distance or (distance == best_distance and best != null and found.id < best.id):
				best_distance = distance
				best = found
				_focus_last_bucket = code
	return best


## Lower bound on the squared distance from [param point] to any living soldier in the
## bucket named by [param code]. Zero when the point is inside the bucket's box.
func _bucket_bound_squared(code: int, point: Vector2) -> float:
	if code >= 0:
		return formations[code].bounds_distance_squared(point)
	var index := -1 - code
	if _loose_count[index] == 0:
		return INF
	var low: Vector2 = _loose_min[index]
	var high: Vector2 = _loose_max[index]
	var dx := maxf(maxf(low.x - point.x, point.x - high.x), 0.0)
	var dy := maxf(maxf(low.y - point.y, point.y - high.y), 0.0)
	return dx * dx + dy * dy


## The living enemy in one bucket nearest to [param point], or null when the bucket has
## nobody left in it.
##
## The side test is not redundant even though a bucket is collected by side: a soldier's
## membership can be changed by an order and a body is not the authority on which side a
## soldier fights for. Cheap insurance, and the sort that costs one comparison rather than
## one bug.
func _nearest_in_bucket(code: int, enemy_side: String, point: Vector2) -> BattleUnit:
	var best: BattleUnit = null
	var best_distance := INF
	if code >= 0:
		var members: Array[BattleUnit] = _body_members[code]
		var count := _body_member_count[code]
		for i in count:
			var unit := members[i]
			if not unit.is_alive() or unit.side != enemy_side:
				continue
			if profile_enabled:
				foc_members_walked += 1
			var distance := point.distance_squared_to(unit.position)
			if distance < best_distance or (distance == best_distance and best != null and unit.id < best.id):
				best_distance = distance
				best = unit
		return best
	var index := -1 - code
	var loose: Array = _loose_units[index]
	var count := _loose_count[index]
	for i in count:
		var unit: BattleUnit = loose[i]
		if unit == null or not unit.is_alive() or unit.side != enemy_side:
			continue
		if profile_enabled:
			foc_members_walked += 1
		var distance := point.distance_squared_to(unit.position)
		if distance < best_distance or (distance == best_distance and best != null and unit.id < best.id):
			best_distance = distance
			best = unit
	return best


## Recompute every body's formation focus for this tick, once, from the summaries just
## rebuilt.
##
## The pass costs one bounded selection per body - and a selection looks at one body's
## soldiers in the ordinary case, not the army's. Before Step 7.5 this was one pass over the
## whole army per body per tick, which is what made it 881 ms a tick at twenty thousand
## soldiers (D-088).
##
## A body with nobody left standing is not evaluated at all. There is no answer worth keeping
## for a corpse: nobody in it can ask, and if it is given soldiers again the next tick
## answers for the body it has become.
func _refresh_focus() -> void:
	if profile_enabled:
		foc_passes += 1
	_refresh_summaries()
	for formation in formations:
		if formation.living_count == 0:
			# A body with nobody standing has no focus to hold: not a stale one from the
			# tick it died on, and not a fresh one, because there is nobody in it for a
			# focus to be for. Writing the empty answer down is what makes that a fact
			# rather than an accident of nobody having asked.
			_apply_focus(formation, null, formation.anchor)
			formation.focus_null_tick = tick_index
			continue
		if profile_enabled:
			foc_evaluations += 1
		var directed := _nearest_enemy_via_buckets(formation.side, formation.anchor)
		_apply_focus(formation, directed, formation.anchor)
		if directed == null:
			# The pass itself found nobody. Nothing can change that inside this tick, so
			# no soldier in this body needs to repair it: the question has already been
			# answered, once, for everybody.
			formation.focus_null_tick = tick_index
		if profile_enabled:
			var previous_id := _focus_previous_id[formation.index]
			if previous_id != (directed.id if directed != null else -1):
				foc_changes += 1
				_foc_changes_this_tick += 1
			_focus_previous_id[formation.index] = directed.id if directed != null else -1
	if profile_enabled:
		_foc_end_tick()


## Write one body's focus answer down, in both halves: the numbers on the body and the
## reference in the one place references are allowed to live.
##
## Kept in one place because the two must agree - a body whose [member
## BattleFormation.focus_distance] described a soldier the battlefield is no longer holding
## would be a body proving that a look finds nobody using a soldier that is not there. The
## version stamp is what makes the pair current.
##
## The focus body is only named when the answer came out of a body at all: an army with no
## bodies has no formation to watch, and saying it watched body -1 would be a lie told by an
## integer. The soldier is still the answer; only the strategic name for it is missing.
func _apply_focus(body: BattleFormation, target: BattleUnit, from_point: Vector2) -> void:
	_focus_unit_by_body[body.index] = target
	body.focus_body_index = _focus_last_bucket if (target != null and _focus_last_bucket >= 0) else -1
	body.focus_distance = INF if target == null else from_point.distance_to(target.position)
	body.focus_version = body.membership_version


## The soldier this body's focus points at, or null when there is nobody - and null for a body
## whose answer was made before its membership changed, because that answer was about a
## different set of soldiers. The single reading path for every consumer.
func _focus_unit_of(body: BattleFormation) -> BattleUnit:
	if body.index < 0 or not body.is_focus_current():
		return null
	return _focus_unit_by_body[body.index]


## The hostile body this one is watching, or null when there is nobody, when the enemy has no
## bodies, or when the answer predates a membership change. The formation-level half of the
## focus: what a body knows strategically, as opposed to the soldier it is pointed at.
func _focus_formation_of(body: BattleFormation) -> BattleFormation:
	if body.index < 0 or not body.is_focus_current():
		return null
	var index := body.focus_body_index
	if index < 0 or index >= formations.size():
		return null
	return formations[index]


## Roll the focus counters' per-tick figures forward. Called at the end of the pass that
## opens a tick's focus work, so "worst tick" means one tick rather than one whole battle.
func _foc_end_tick() -> void:
	foc_scans_worst_tick = maxi(foc_scans_worst_tick, _foc_scans_this_tick)
	foc_units_worst_tick = maxi(foc_units_worst_tick, _foc_units_this_tick)
	foc_changes_worst_tick = maxi(foc_changes_worst_tick, _foc_changes_this_tick)
	_foc_scans_this_tick = 0
	_foc_units_this_tick = 0
	_foc_changes_this_tick = 0


## Who this soldier faces when there is nobody inside its own search bound.
##
## [b]Its body's answer, read rather than worked out.[/b] This is the whole of soldier
## consumption, and it is a field read on the formation: the same cost as reading the
## soldier's own position, and no question asked of anybody else. There is no scan here and,
## since Step 7.5, no path that reaches one - a soldier whose body was answered this tick
## reads that answer.
##
## The two repairs below are the only work anyone does here, and both are bounded.
## [b]A body's answer that died mid-tick[/b] is worked out again at the body's layer - one
## bounded selection, not one walk of the army - and only until the body's answer is a
## soldier again; a body whose focus was found to be nobody at all is not asked a second
## time this tick, because nothing can come back to life inside a tick and the second answer
## would be the first one. [b]A side with no bodies to ask for it[/b] is answered once per
## tick on the same terms. A death therefore becomes one correction at the level that owns
## it, rather than a search per soldier standing near it. See D-090.
func _focus_target(unit: BattleUnit) -> BattleUnit:
	if profile_enabled:
		foc_target_calls += 1
	if focus_inline_enabled:
		# The formed-soldier fast path, spelled out. A soldier in a body almost always asks a
		# question his body already has the answer to, and he asked it through four calls:
		# `_side_index`, `_focus_unit_of`, that function's `is_focus_current`, and `is_alive`.
		# Twenty thousand soldiers pay that every tick for an answer that is one read and two
		# comparisons wide. The guards below are those functions' guards, in their order, evaluated
		# at the same point in the tick; nothing is remembered between calls, so there is nothing to
		# invalidate - this is dispatch removal, not a cache. See D-115.
		var hot_body := unit.formation_ref
		if hot_body != null and hot_body.index >= 0 and hot_body.is_focus_current():
			var hot_directed: BattleUnit = _focus_unit_by_body[hot_body.index]
			if hot_directed != null and hot_directed.alive and hot_directed.hp > 0:
				if profile_enabled:
					foc_formation_hits += 1
				return hot_directed
	var index := _side_index(unit.side)
	if unit.formation_ref != null:
		var body := unit.formation_ref
		var directed := _focus_unit_of(body)
		if directed != null and directed.is_alive():
			if profile_enabled:
				foc_formation_hits += 1
			return directed
		if body.index >= 0 and body.focus_null_tick != tick_index:
			if profile_enabled:
				foc_formation_repairs += 1
			directed = _nearest_enemy_via_buckets(unit.side, body.anchor)
			_apply_focus(body, directed, body.anchor)
			if directed == null:
				# There is nobody to be pointed at, and that cannot change inside a tick.
				body.focus_null_tick = tick_index
			else:
				if profile_enabled:
					foc_formation_hits += 1
				return directed
	if _side_focus_tick[index] == tick_index:
		# This side has already been asked, and by the side's own answer: a soldier still
		# standing, or nobody at all.
		var cached: BattleUnit = _focus_by_side[index]
		if cached == null:
			if profile_enabled:
				foc_side_uses += 1
			return null
		if cached.is_alive():
			if profile_enabled:
				foc_side_uses += 1
			return cached
	if profile_enabled:
		foc_side_repairs += 1
	var by_side := _nearest_enemy_via_buckets(unit.side, _side_centre(unit.side))
	_focus_by_side[index] = by_side
	_side_focus_tick[index] = tick_index
	return by_side


## The average position of a side's living soldiers, or the middle of the field when it has
## none left to average.
##
## Read out of the summary pass rather than recalculated. This used to walk the whole army
## every time a soldier with no body to ask for it wanted to know where its side was
## standing - the same per-soldier scan the milestone removes - and the figure is now the one
## the tick began with rather than one taken midway through the soldiers' own movement. That
## makes it a fact about the tick instead of a fact about how far down the roster the caller
## happens to be, which is what the summary layer is for. See D-089.
##
## The summary is refreshed here if this tick has not built one, so the question has a
## correct answer whenever it is asked rather than only after the focus pass has run.
func _side_centre(side: String) -> Vector2:
	if _summary_tick != tick_index:
		_refresh_summaries()
	var index := _side_index(side)
	if profile_enabled:
		foc_side_centre_reads += 1
	if not _sides_built and _side_centre_tick[index] != tick_index:
		# Every soldier is in a body, so the pass did not walk the army - and this is the one
		# caller that wants to know where a side is standing. Walked here, once for the side,
		# for the battle that has soldiers with no body to ask for it.
		_side_centre_tick[index] = tick_index
		var total := Vector2.ZERO
		var standing := 0
		for unit in units:
			if unit.is_alive() and _side_index(unit.side) == index:
				total += unit.position
				standing += 1
		_side_sum[index] = total
		_side_living[index] = standing
	var count := _side_living[index]
	if count == 0:
		return field_size * 0.5
	return _side_sum[index] / float(count)


## The living enemy nearest to a point, ties to the lower id, or null when that side has
## nobody left. A plain scan of the whole army.
##
## [b]This is the reference implementation, and the battle no longer calls it.[/b] It is what
## the bounded selection in [method _nearest_enemy_via_buckets] is proved against: the tests
## drive live battles and compare the two answers body by body and tick by tick, which is a
## stronger statement than any argument about bounds (D-089). It is kept in the simulator
## rather than in a test file because a reference that lives beside what it checks stays
## honest, and because [member foc_global_scans] counts its callers - a counter whose expected
## value is zero is only worth having if the thing it counts can still happen.
##
## [param source] names where the question came from and is development-only. It has no effect
## on the answer. See D-088.
func _nearest_enemy_to_point(side: String, point: Vector2, source: String = "") -> BattleUnit:
	var enemy_side := enemy_side_of(side)
	var best: BattleUnit = null
	var best_distance := INF
	for unit in units:
		if not unit.is_alive() or unit.side != enemy_side:
			continue
		var distance := point.distance_squared_to(unit.position)
		if distance < best_distance or (distance == best_distance and best != null and unit.id < best.id):
			best_distance = distance
			best = unit
	if profile_enabled:
		# Counted once per scan rather than once per unit: a per-iteration counter would
		# cost a noticeable share of the thing it is measuring, and the walks are what the
		# phase clock already prices.
		foc_global_scans += 1
		foc_units_examined += units.size()
		_foc_scans_this_tick += 1
		_foc_units_this_tick += units.size()
		match source:
			"formation":
				foc_scans_from_formations += 1
				foc_units_from_formations += units.size()
			"soldier":
				foc_scans_from_soldiers += 1
				foc_units_from_soldiers += units.size()
			_:
				foc_scans_direct += 1
	return best


## The nearest living enemy within [param radius], ties broken by the lower unit id.
##
## The tie-break is explicit rather than left to whichever candidate the grid happened
## to hand back first. A bucket is a linked list, its order is an implementation detail,
## and letting it decide who a soldier attacks would make the battle depend on how the
## grid was built - which is precisely the class of nondeterminism a spatial index is
## not allowed to introduce. Distance first, then id, and the same rule everywhere.
func _nearest_enemy_within(unit: BattleUnit, enemy_side: String, radius: float) -> BattleUnit:
	if grid == null:
		return null
	if grid.backend == BattleSpatialGrid.Backend.NATIVE_FULL and grid.can_answer_natively():
		# Shape B: the whole query, exact test included, answered in the accelerator. The
		# live positions it tests against are mirrored from this battle's own mutation
		# points, and the shape counters below are read from the same fields the reference
		# walk writes, so the profile means the same thing either way.
		var best: BattleUnit = grid.native_nearest(unit, enemy_side, radius)
		if profile_enabled:
			tgt_candidates += grid.native_last_candidates()
			tgt_candidates_max = maxi(tgt_candidates_max, grid.native_last_candidates())
		return best
	if grid.backend == BattleSpatialGrid.Backend.COMPARE_FULL and grid.can_answer_natively():
		# Correctness only: the reference ladder stays authoritative and the accelerator's
		# answer is compared against it, rung for rung. Never used for performance.
		var reference := _nearest_enemy_within_reference(unit, enemy_side, radius)
		var native_answer: BattleUnit = grid.native_nearest(unit, enemy_side, radius)
		grid.note_answer(unit, radius, reference, native_answer)
		return reference
	return _nearest_enemy_within_reference(unit, enemy_side, radius)


## The locked query: the grid walk for candidates, then the exact test against live positions.
func _nearest_enemy_within_reference(unit: BattleUnit, enemy_side: String, radius: float) -> BattleUnit:
	grid.collect_within(unit.position, radius, enemy_side, _query_scratch)
	if profile_enabled:
		# What the broadphase handed over, before the exact test below throws most of it
		# away. This is the figure that says whether a search is cheap because there is
		# nobody about or expensive because there is.
		tgt_candidates += _query_scratch.size()
		tgt_candidates_max = maxi(tgt_candidates_max, _query_scratch.size())
	var best: BattleUnit = null
	var best_distance := INF
	var limit := radius * radius
	for candidate in _query_scratch:
		var distance := unit.position.distance_squared_to(candidate.position)
		# The radius is a promise, not a hint. A query returns a box, and the box is
		# deliberately larger than the circle - which is harmless for [i]finding[/i] the
		# nearest, because a superset cannot hide one, but fatal for the escalation:
		# the caller stops at the first radius that returns anything, so a candidate
		# half a cell beyond the radius would end the search early and answer with a
		# soldier that is not the nearest after all. Filtering here is what makes
		# "the first radius that finds anyone contains the nearest" true rather than
		# nearly true. See D-065.
		if distance > limit:
			continue
		if distance < best_distance or (distance == best_distance and best != null and candidate.id < best.id):
			best_distance = distance
			best = candidate
	return best


## Refresh the proximity index for this tick, and tell it how far a soldier may have
## walked since the snapshot.
##
## One linear pass. The margin is what stops a cell boundary becoming an invisible wall:
## the grid records where everyone stood at the start of the tick, soldiers move during
## it, and without widening the search by the furthest anyone could have moved, a
## soldier who crossed into the next cell would be missing from queries that should
## have found them.
func _rebuild_spatial(delta: float) -> void:
	if grid == null:
		return
	# Step 7.7. The backend belongs to the battle, not to the grid instance, so it is applied
	# here - one assignment a tick - and the stamp below is what lets a disagreement be
	# reported with the tick that produced it.
	grid.backend = target_backend
	grid.dev_tick = tick_index
	# Step 7.6. The grid's own cell counters follow this simulator's profile flag, set once a
	# tick rather than read per query, so a battle that is not being measured pays one
	# comparison per tick for the counters it is not keeping.
	grid.dev_profile = profile_enabled
	# Terrain only ever slows a unit, so the fastest base speed bounds the step. The
	# half-unit of slack absorbs the separation pushes that happen later in the tick.
	grid.query_margin = _fastest_speed * absf(delta) + 0.5
	grid.rebuild(units)


## Build this tick's hunter chains: every soldier holding an attack order is chained onto the enemy he
## was ordered to kill, so a death can clear its hunters by walking one short chain instead of the
## whole army. One pass over the roster a tick, and only over the soldiers who hold an order at all -
## a deployed army has a handful, and an army ordered at one enemy has a single chain.
##
## A snapshot, like the spatial grid, so there is no update path to get wrong; and an order that was
## cleared after the chains were built is skipped when the chain is walked, because the walk re-checks
## each soldier's own order before touching it. See D-111.
func _rebuild_order_index() -> void:
	_order_index_tick = tick_index
	if _order_head.is_empty():
		return
	_order_head.fill(-1)
	for unit in units:
		var quarry := unit.attack_order_target_id
		if quarry < 0 or quarry >= _order_head.size():
			continue
		if unit.id < 0 or unit.id >= _order_next.size():
			continue
		# Push onto the front of the quarry's chain. The order inside a chain never reaches the
		# result, because every entry in it is cleared.
		_order_next[unit.id] = _order_head[quarry]
		_order_head[quarry] = unit.id


## Which implementation answers the automatic target search's spatial queries. See
## [enum BattleSpatialGrid.Backend]. Defaults to the locked GDScript reference; the benchmark
## and the tests change it directly, and a real run can select the accelerator with the
## PB_TARGET_BACKEND environment variable (`PB_TARGET_BACKEND=native`), which exists so the
## windowed smoke test exercises the accelerated path deliberately rather than by accident.
var target_backend: int = 0


## What the query backend did this battle - calls, disagreements, time in the accelerator.
func backend_report() -> Dictionary:
	if grid == null:
		return {"backend": target_backend, "native_calls": 0, "native_mismatches": 0}
	return grid.backend_report()


func _move_toward(unit: BattleUnit, point: Vector2, delta: float) -> void:
	if profile_enabled:
		upd_moves += 1
	var to_point := point - unit.position
	if to_point.length() <= 0.0001:
		return
	if profile_enabled:
		mv_normalises += 1
	# One write statement, whichever path worked out the speed: the battle moves a soldier's position
	# in exactly three places, and the suite counts them, because D-095's accelerator mirror is only
	# true while every write is known. See D-114.
	var speed := unit.move_speed
	if terrain_speed_inline:
		# The same rule as `_effective_speed`, applied without the call: this runs once per moving
		# soldier per tick.
		if terrain != null:
			if profile_enabled:
				mv_terrain_lookups += 1
			speed *= terrain.move_multiplier_at(unit.position)
	else:
		speed = _effective_speed(unit)
	unit.position += to_point.normalized() * speed * delta
	unit.position = Vector2(
		clampf(unit.position.x, 0.5, field_size.x - 0.5),
		clampf(unit.position.y, 0.5, field_size.y - 0.5)
	)
	if grid != null:
		# One of the battle's two live-state mutation points - the other is death, where the
		# killing blow lands. The accelerator's mirrored positions are only true because
		# these two are the only places a soldier's live state changes inside a tick, and
		# COMPARE_FULL is what proves that. See D-095.
		if profile_enabled:
			mv_native_calls += 1
		grid.native_moved(unit)


## Move a soldier who is already in his place by the step his body took. The clamp and the grid
## notification are the same as [method _move_toward]'s, because the grid's mirrored positions are
## only true while these remain the only places a live soldier's position is written. See D-095.
func _step_with_body(unit: BattleUnit, step_vector: Vector2) -> void:
	unit.position = Vector2(
		clampf(unit.position.x + step_vector.x, 0.5, field_size.x - 0.5),
		clampf(unit.position.y + step_vector.y, 0.5, field_size.y - 0.5)
	)
	if grid != null:
		if profile_enabled:
			mv_native_calls += 1
		grid.native_moved(unit)


## A soldier's speed over the ground it is standing on.
##
## The rule - base speed times the multiplier of the ground under his feet - is stated here for the
## reference path, and [method _move_toward] applies the identical rule inline for the per-soldier path,
## which cannot afford a call per soldier to ask it. [method BattlefieldTerrain.move_multiplier_via_cells]
## is the previous shape, kept so the two paths can be measured against each other in one build.
func _effective_speed(unit: BattleUnit) -> float:
	if terrain == null:
		return unit.move_speed
	if profile_enabled:
		mv_terrain_lookups += 1
	return unit.move_speed * terrain.move_multiplier_via_cells(unit.position)


## Push apart soldiers standing on top of each other, through the separation pass's own
## index rather than through the targeting grid.
##
## [b]What this replaced.[/b] Step 7.2 asked the targeting grid, once per soldier, for
## everyone within a box twice as wide as the separation distance, then measured all of
## them and acted on almost none. Measured on the fixed-area benchmark at five thousand
## soldiers, that was 95.6 candidates per soldier to find 226 touching pairs army-wide,
## and the broadphase alone was 62 to 66 per cent of the phase.
##
## [b]What it is now.[/b] [BattleOverlapGrid] pairs cells rather than asking soldiers
## questions, with a cell sized for bodies instead of for eyesight, and every physical
## pair is produced exactly once. The pushes are accumulated per soldier and applied once
## at the end, so the outcome does not depend on the order pairs were visited in.
##
## [b]What has not changed.[/b] Every soldier is still simulated. Nothing is merged,
## skipped, disabled or approximated: enemy contact is resolved by the same code as
## friendly contact, a forming body is resolved by the same code as a broken one, and the
## only pairs that are skipped at all are the ones a formation's own geometry has already
## proved are not touching. See D-074.
func _resolve_overlaps() -> void:
	if overlap_grid == null:
		return
	overlap_grid.stats_enabled = profile_enabled
	overlap_grid.max_push = max_separation_push
	# Only the spike sampler needs the tick's own cost; a per-tick clock read in a normal
	# battle would be the profiler measuring itself.
	var tick_clock := Time.get_ticks_usec() if (profile_enabled and sample_phases) else 0
	overlap_grid.resolve(units, separation_radius * SEPARATION_FACTOR, separation_settle_epsilon)
	if profile_enabled:
		_pull_overlap_stats()
	if tick_clock > 0:
		var usec := Time.get_ticks_usec() - tick_clock
		if usec > _overlap_worst_usec:
			_overlap_worst_usec = usec
			overlap_worst_report = overlap_stats
	# The comparison modes record when a disagreement happened rather than only that one did.
	# Nothing is applied from the comparison: the reference's result is the one that moved.
	var native_pass := overlap_grid as BattleOverlapNative
	if native_pass != null:
		if native_pass.compare_enabled:
			native_pass.note_tick(tick_index)
		if profile_enabled:
			# The boundary's own decomposition, so the profile can say what the accelerator
			# cost rather than only what the phase did.
			var boundary := native_pass.boundary_report()
			profile["overlap_sync"] = float(profile.get("overlap_sync", 0.0)) + float(boundary["sync_us"]) / 1000.0
			profile["overlap_native"] = float(profile.get("overlap_native", 0.0)) + float(boundary["native_us"]) / 1000.0
			profile["overlap_apply"] = float(profile.get("overlap_apply", 0.0)) + float(boundary["apply_us"]) / 1000.0


## Copy the separation pass's counters and density picture into one dictionary. Called
## once per tick and only while profiling, so a normal battle pays nothing for it.
func _pull_overlap_stats() -> void:
	overlap_stats = overlap_grid.report()


## The worst overlap tick's own counters, with the tick's cost in microseconds. Development
## only: empty unless the per-tick sampler has been running.
func overlap_worst() -> Dictionary:
	if overlap_worst_report.is_empty():
		return {}
	var out := overlap_worst_report.duplicate()
	out["usec"] = _overlap_worst_usec
	return out


## What the separation pass's backend is, and - when it is the native one - what the boundary
## cost. Shaped like [method backend_report], and never used for anything but reporting.
func overlap_backend_report() -> Dictionary:
	var native_pass := overlap_grid as BattleOverlapNative
	if native_pass == null:
		return {"backend": overlap_backend_active, "sync_us": 0, "native_us": 0,
			"apply_us": 0, "total_us": 0, "mismatches": 0, "passes": 0}
	var report := native_pass.boundary_report()
	report["backend"] = overlap_backend_active
	return report


func _check_victory() -> void:
	var players := side_count(BattleContext.SIDE_PLAYER)
	var enemies := side_count(BattleContext.SIDE_ENEMY)
	if players > 0 and enemies > 0:
		return
	if players == 0 and enemies == 0:
		_finish("")
	elif players == 0:
		_finish(BattleContext.SIDE_ENEMY)
	else:
		_finish(BattleContext.SIDE_PLAYER)


func _finish(winner_side: String) -> void:
	state = State.FINISHED
	winner = winner_side
	events.append({"type": "finished", "winner": winner_side, "elapsed": elapsed})
	DebugLogger.info("battle finished after %.1fs, winner: %s" % [
		elapsed, winner_side if not winner_side.is_empty() else "none",
	], "Battle")
