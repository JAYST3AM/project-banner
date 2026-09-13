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

## Development-only timing accumulators. Off by default and free when off: every read
## of them is behind a boolean, and nothing is measured unless the benchmark asks.
## Deliberately coarse - phase-level, plus one pair of clock reads per soldier for
## targeting - because the point is to say which phase costs what, not to profile
## individual statements. See D-064.
var profile_enabled: bool = false
var profile: Dictionary = {}

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
		target_search_radius = maxf(0.5, config.get_float("battle.target_search_radius", 8.0))
		target_search_escalation = maxf(1.05, config.get_float("battle.target_search_escalation", 4.0))
		target_search_max_radius = config.get_float("battle.target_search_max_radius", 32.0)
	# The bound is what keeps a target search local. A ceiling of zero - or anything
	# below the starting radius - would mean a per-soldier search of the whole
	# battlefield, which is precisely the cost this milestone exists to remove, so it is
	# repaired to the starting radius rather than honoured. See D-067.
	target_search_max_radius = maxf(target_search_radius, target_search_max_radius)
	grid = BattleSpatialGrid.new()
	grid.configure(field_size, cell_size)


func add_units(p_units: Array[BattleUnit]) -> void:
	units = p_units
	_unit_by_id.clear()
	_fastest_speed = 0.0
	for unit in units:
		_unit_by_id[unit.id] = unit
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


func _update_unit(unit: BattleUnit, delta: float) -> void:
	unit.cooldown_left = maxf(0.0, unit.cooldown_left - delta)

	var target_probe := 0
	if profile_enabled:
		target_probe = Time.get_ticks_usec()
	var target := _choose_target(unit)
	if target_probe > 0:
		_profile_accumulate("target", target_probe)
	if target == null:
		return
	# An explicit attack order wins over automatic target selection, but only
	# while the ordered target is still standing.
	if unit.attack_order_target_id >= 0:
		var ordered := find_unit(unit.attack_order_target_id)
		if ordered != null and ordered.is_alive() and ordered.side != unit.side:
			target = ordered
		else:
			unit.attack_order_target_id = -1

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


## The nearest living enemy to this soldier.
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
func _choose_target(unit: BattleUnit) -> BattleUnit:
	var enemy_side := enemy_side_of(unit.side)
	var radius := target_search_radius
	while true:
		var best := _nearest_enemy_within(unit, enemy_side, radius)
		if best != null:
			return best
		if radius >= target_search_max_radius:
			break
		radius = minf(target_search_max_radius, radius * target_search_escalation)
	return _focus_target(unit)


## Recompute every body's long-range focus. Linear in the army, and run once per tick,
## which is the whole point: the expensive question is asked a handful of times rather
## than once per soldier. A battle with no formations pays nothing at all.
func _refresh_focus() -> void:
	_focus_by_formation.clear()
	_focus_by_side.clear()
	for formation in formations:
		_focus_by_formation[formation.id] = _nearest_enemy_to_point(formation.side, formation.anchor)


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


## Push apart soldiers standing on top of each other, through the proximity index
## rather than through every pair on the field.
##
## [b]Each pair is resolved once[/b], by the rule that only the soldier with the lower id
## handles it. Without that rule an overlapping pair would be pushed twice - once from
## each side - and the second push would be a second independent event rather than the
## same one, which doubles the work and makes the result depend on which soldier was
## considered first. The rule is stated in ids rather than in array positions so that it
## survives any future reordering of the unit list.
##
## [b]The order is preserved deliberately.[/b] The outer loop walks the unit list and the
## inner one walks a bucket, and insertion appends rather than prepends, so the pairs
## come out in the same relative order the old pairwise loop used. Since a pair that is
## out of range does nothing, skipping the far ones is a no-op - which is why this
## produces the same positions the exhaustive version did rather than merely an equally
## defensible set. A test checks that directly. See D-062.
func _resolve_overlaps() -> void:
	var minimum := separation_radius * SEPARATION_FACTOR
	if grid == null:
		return
	# Its own rebuild rather than the tick's earlier one. Every soldier has walked since
	# that snapshot, and the overlap pass is the phase where being a body's-width behind
	# actually matters. The margin on top covers the pushes this very pass is making:
	# a pair nudged together by a third soldier's shove should still be seen.
	grid.query_margin = minimum
	grid.rebuild(units)
	for unit in units:
		if not unit.is_alive():
			continue
		grid.collect_within(unit.position, minimum, "", _query_scratch)
		for other in _query_scratch:
			if other.id <= unit.id:
				continue
			var offset := other.position - unit.position
			var distance := offset.length()
			if distance >= minimum:
				continue
			var push := (minimum - distance) * 0.5
			var direction := offset.normalized() if distance > 0.0001 else Vector2.RIGHT
			unit.position -= direction * push
			other.position += direction * push


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
