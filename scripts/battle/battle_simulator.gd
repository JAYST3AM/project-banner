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
## instead - by its body if it is formed, by its side if it is not. That is one pass over
## the army per formation and per side, once per tick, rather than one pass per soldier
## per tick. See D-067.
var _focus_by_formation: Dictionary = {}
var _focus_by_side: Dictionary = {}

## How far each body's focus enemy is from that body's anchor, in world units, INF when
## there is nobody to be pointed at. Kept alongside [member _focus_by_formation] rather
## than looked up on demand, and it is what lets a soldier prove that a look would find
## nobody before paying for it. See [method _focus_look_finds_nobody].
var _focus_distance_by_formation: Dictionary = {}

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
		target_retention_radius = maxf(0.0, config.get_float("battle.target_retention_radius", 32.0))
		target_switch_advantage = maxf(1.0, config.get_float("battle.target_switch_advantage", 1.25))
		target_immediate_on_contact_loss = config.get_bool("battle.target_immediate_on_contact_loss", true)
		target_contact_loss_factor = maxf(0.0, config.get_float("battle.target_contact_loss_factor", 1.0))
	grid = BattleSpatialGrid.new()
	grid.configure(field_size, cell_size)
	overlap_grid = BattleOverlapGrid.new()
	overlap_grid.configure(field_size, overlap_cell_size)
	overlap_grid.max_push = max_separation_push


func add_units(p_units: Array[BattleUnit]) -> void:
	units = p_units
	_unit_by_id.clear()
	_fastest_speed = 0.0
	# A soldier's awareness slot is derived from its own id and nothing else, which is
	# what makes the schedule deterministic: the same roster in the same order gives the
	# same phases, and re-ordering the roster changes the order soldiers are updated in
	# but not when any one of them looks around. See D-080.
	var interval := maxi(1, target_reacquisition_ticks)
	for unit in units:
		_unit_by_id[unit.id] = unit
		unit.auto_target_id = -1
		unit.next_search_tick = posmod(unit.id, interval)
		if unit.is_alive():
			_fastest_speed = maxf(_fastest_speed, unit.move_speed)


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
	formations.append(formation)
	_formations_by_id[formation.id] = formation


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
		formation.advance(delta, _formation_speed(formation))
		formation.ensure_slots()
		formation.update_cohesion(_unit_by_id, _cohesion_reference(formation))


## Where a body that has been told to close with the enemy wants its centre to be.
##
## Normally it stops a rank's depth short of the enemy centre: a formation decides
## where the body stands, and whether that puts steel in reach is the soldiers'
## business.
##
## The exception is the stalled battle, and it is judged per body rather than per side.
## If [i]this[/i] formation has nobody in contact - its line broken, a survivor standing
## in a gap wider than a sword, nobody in it able to reach anybody - then stopping short
## leaves it standing a few feet from an enemy it cannot touch, forever. So a body that
## is not itself in contact closes the whole way. Whether the rest of the army is
## fighting is not this body's business: a wing that has not reached the enemy must be
## able to close even while the centre is engaged, which is why contact is a property of
## a formation and not of a side. See D-056.
##
## The check costs one boolean, because the per-soldier reach test already had to be
## made.
func _engage_target_for(formation: BattleFormation) -> Vector2:
	var target := _nearest_enemy_formation(formation)
	if target == null:
		return formation.anchor
	var to_target := target.anchor - formation.anchor
	var distance := to_target.length()
	if distance <= 0.0001:
		return formation.anchor
	if formation.in_contact:
		var stop := (formation.depth() + target.depth()) * 0.5 + contact_gap
		return target.anchor - (to_target / distance) * stop
	return target.anchor


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
	if body.order != BattleFormation.ORDER_ENGAGE:
		return false
	if body.is_moving() or body.is_turning() or body.is_reforming():
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



func start() -> void:
	state = State.RUNNING
	elapsed = 0.0


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
	_profile_stop("formation", phase)

	# One linear pass to index everyone, then every proximity question this tick is
	# answered locally. This is the whole of Step 7.2's cost model: the battlefield is
	# described once so that no soldier has to look at the battlefield.
	phase = _profile_start()
	_rebuild_spatial(delta)
	_profile_stop("grid", phase)

	# After the bodies have moved and before anyone asks, so a formation's focus is its
	# focus for this tick rather than for wherever it stood last tick.
	phase = _profile_start()
	_refresh_focus()
	_profile_stop("focus", phase)

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
	tgt_searches = 0
	tgt_successful_searches = 0
	tgt_empty_searches = 0
	tgt_rung_hits = PackedInt32Array()
	tgt_focus_fallbacks = 0
	tgt_focus_proven = 0
	tgt_explicit_order_uses = 0
	tgt_order_clears = 0
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
	if profile_enabled:
		tgt_soldier_ticks += 1

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
			if profile_enabled:
				tgt_explicit_order_uses += 1
		else:
			unit.attack_order_target_id = -1
			if profile_enabled:
				tgt_order_clears += 1

	if target == null:
		var target_probe := 0
		if profile_enabled:
			target_probe = Time.get_ticks_usec()
		target = _resolve_target(unit)
		if target_probe > 0:
			_profile_accumulate("target", target_probe)
	if target == null:
		return

	unit.facing = (target.position - unit.position).normalized()

	if unit.position.distance_to(target.position) <= unit.attack_range:
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
		# Pressing forward is the one exception, and it is deliberately narrow. A body
		# that has stopped, has been told to engage, and has nobody on its side
		# fighting has no line left to hold: the fighting has stopped happening, and
		# the nearest men crossing the gap is what starts it again. While anyone on
		# this side is in contact the dressing wins, which is what stops a battle
		# dissolving into a crowd.
		if _can_press_forward(unit, body):
			_move_toward(unit, target.position, delta)
			return
		var place := unit.formation_slot()
		if unit.position.distance_to(place) > ARRIVE_EPSILON:
			_move_toward(unit, place, delta)
		return

	if unit.has_move_order:
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
		for unit in units:
			if unit.attack_order_target_id == target.id:
				unit.attack_order_target_id = -1


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
	var retained := _retained_target(unit)
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
		if profile_enabled:
			tgt_focus_fallbacks += 1
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
	if _focus_look_finds_nobody(unit):
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
		if retained != null and not _clear_improvement(unit, retained, local):
			local = retained
		_store_target(unit, local)
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
	return _focus_target(unit)


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
	var reachable: float = float(_focus_distance_by_formation.get(body.id, INF))
	if reachable == INF:
		# Nobody on the other side at all: nothing to find and nothing to be pointed at.
		return true
	var margin := grid.query_margin if grid != null else 0.0
	var bound := reachable - unit.position.distance_to(body.anchor) - margin
	return bound > _search_ceiling_of(unit)


## The nearest living enemy inside this soldier's own awareness bound, or null when there
## is nobody local.
##
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
	while true:
		rung += 1
		var best := _nearest_enemy_within(unit, enemy_side, radius)
		if profile_enabled:
			if tgt_rung_hits.size() < rung:
				tgt_rung_hits.resize(rung)
			tgt_rung_hits[rung - 1] += 1
		if best != null:
			return best
		var widened := minf(ceiling, radius * target_search_escalation)
		# Two ways out, and both are needed: the ladder is done when it has reached its
		# ceiling, and it is stuck when widening cannot widen any further. A ladder that
		# cannot terminate is a per-soldier scan of the whole battlefield by another name.
		if radius >= ceiling or widened <= radius:
			break
		radius = widened
	return null


## The nearest living enemy to this soldier, or the enemy its body is pointed at when
## there is nobody within its own bound. This is the whole of the local search, and it is
## unchanged by Step 7.4: the milestone changed how often it is asked, never what it
## answers.
func _choose_target(unit: BattleUnit) -> BattleUnit:
	var best := _nearest_local_enemy(unit)
	if best != null:
		return best
	return _focus_target(unit)


## Recompute every body's long-range focus. Linear in the army, and run once per tick,
## which is the whole point: the expensive question is asked a handful of times rather
## than once per soldier. A battle with no formations pays nothing at all.
func _refresh_focus() -> void:
	_focus_by_formation.clear()
	_focus_by_side.clear()
	_focus_distance_by_formation.clear()
	for formation in formations:
		var directed := _nearest_enemy_to_point(formation.side, formation.anchor)
		_focus_by_formation[formation.id] = directed
		_focus_distance_by_formation[formation.id] = (
			INF if directed == null else formation.anchor.distance_to(directed.position))


## Who this soldier faces when there is nobody inside its own search bound.
##
## The side fallback is computed on demand rather than every tick because a battle with
## formations never asks for it, and a battle without them is a small one where a single
## extra pass costs nothing.
func _focus_target(unit: BattleUnit) -> BattleUnit:
	if unit.formation_ref != null:
		var body := unit.formation_ref
		var directed: BattleUnit = _focus_by_formation.get(body.id)
		if directed == null or not directed.is_alive():
			# It fell this tick, after the focus was taken. Recomputing costs one pass
			# over the army - once for the body, not once for every soldier in it.
			directed = _nearest_enemy_to_point(unit.side, body.anchor)
			_focus_by_formation[body.id] = directed
			_focus_distance_by_formation[body.id] = (
				INF if directed == null else body.anchor.distance_to(directed.position))
		if directed != null:
			return directed
	var by_side: BattleUnit = _focus_by_side.get(unit.side)
	if by_side != null and by_side.is_alive():
		return by_side
	by_side = _nearest_enemy_to_point(unit.side, _side_centre(unit.side))
	_focus_by_side[unit.side] = by_side
	return by_side


## The average position of a side's living soldiers, or the middle of the field when it
## has none left to average.
func _side_centre(side: String) -> Vector2:
	var total := Vector2.ZERO
	var count := 0
	for unit in units:
		if unit.is_alive() and unit.side == side:
			total += unit.position
			count += 1
	if count == 0:
		return field_size * 0.5
	return total / float(count)


## The living enemy nearest to a point, ties to the lower id, or null when that side has
## nobody left. A plain scan, called once per formation per tick and never per soldier.
func _nearest_enemy_to_point(side: String, point: Vector2) -> BattleUnit:
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
	# Terrain only ever slows a unit, so the fastest base speed bounds the step. The
	# half-unit of slack absorbs the separation pushes that happen later in the tick.
	grid.query_margin = _fastest_speed * absf(delta) + 0.5
	grid.rebuild(units)


func _move_toward(unit: BattleUnit, point: Vector2, delta: float) -> void:
	var to_point := point - unit.position
	if to_point.length() <= 0.0001:
		return
	unit.position += to_point.normalized() * _effective_speed(unit) * delta
	unit.position = Vector2(
		clampf(unit.position.x, 0.5, field_size.x - 0.5),
		clampf(unit.position.y, 0.5, field_size.y - 0.5)
	)


## A soldier's speed over the ground it is standing on. Terrain is read here and
## nowhere else, so the rule lives in one place and every kind of movement - formed,
## ordered, or chasing - gets it for free.
func _effective_speed(unit: BattleUnit) -> float:
	if terrain == null:
		return unit.move_speed
	return unit.move_speed * terrain.move_multiplier_at(unit.position)


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
	overlap_grid.resolve(units, separation_radius * SEPARATION_FACTOR, separation_settle_epsilon)
	if profile_enabled:
		_pull_overlap_stats()


## Copy the separation pass's counters and density picture into one dictionary. Called
## once per tick and only while profiling, so a normal battle pays nothing for it.
func _pull_overlap_stats() -> void:
	overlap_stats = overlap_grid.report()


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
