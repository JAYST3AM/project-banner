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

## Side -> whether any soldier of that side currently has an enemy within reach.
## Rebuilt every step inside the per-soldier loop that already makes that comparison,
## so it costs a boolean rather than a search. The formation stances read it to decide
## whether a body is fighting or merely standing near the enemy.
var _in_contact: Dictionary = {}

var field_size: Vector2 = Vector2(100.0, 60.0)
var separation_radius: float = 1.5
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
	_in_contact = {BattleContext.SIDE_PLAYER: false, BattleContext.SIDE_ENEMY: false}


func add_units(p_units: Array[BattleUnit]) -> void:
	units = p_units
	_unit_by_id.clear()
	for unit in units:
		_unit_by_id[unit.id] = unit


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
## held them first, so detaching a group never leaves its men standing in two places at
## once - which is the sort of thing that only shows up as two formations both believing
## they own a soldier, and then as a very strange battle.
func assign_formation(formation: BattleFormation, unit_ids: Array[int]) -> void:
	if formation == null:
		return
	var wanted := {}
	for unit_id in unit_ids:
		wanted[unit_id] = true

	for other in formations:
		if other == formation:
			continue
		var removed := false
		for existing in other.unit_ids.duplicate():
			if wanted.has(existing):
				other.unit_ids.erase(existing)
				removed = true
		if removed:
			other.ensure_slots()
			_sync_formation_slots(other)

	for existing in formation.unit_ids:
		var unit: BattleUnit = _unit_by_id.get(existing)
		if unit != null and not wanted.has(existing):
			unit.formation_ref = null
			unit.slot_index = -1
	formation.unit_ids.clear()
	formation.unit_ids.append_array(unit_ids)
	formation.ensure_slots()
	_sync_formation_slots(formation)


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
## The exception is the stalled battle. If the lines have stopped touching - the enemy
## line broken, a survivor standing in a gap wider than a sword, nobody able to reach
## anybody - then stopping short leaves both armies standing a few feet apart forever.
## So a body whose side is not in contact at all closes the whole way. The check costs
## one flag, because the per-soldier reach test already had to be made.
func _engage_target_for(formation: BattleFormation) -> Vector2:
	var target := _nearest_enemy_formation(formation)
	if target == null:
		return formation.anchor
	var to_target := target.anchor - formation.anchor
	var distance := to_target.length()
	if distance <= 0.0001:
		return formation.anchor
	if bool(_in_contact.get(formation.side, false)):
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
## a body still marching is dressing, not fighting. And nobody on this side may
## currently be within reach of anybody, because if the line is fighting then the line
## is what matters and a soldier leaving it is a hole opening in it.
func _can_press_forward(unit: BattleUnit, body: BattleFormation) -> bool:
	if body == null or unit.slot_index < 0:
		return false
	if body.order != BattleFormation.ORDER_ENGAGE:
		return false
	if body.is_moving() or body.is_turning() or body.is_reforming():
		return false
	return not bool(_in_contact.get(unit.side, false))


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
	_update_formations(delta)

	_in_contact[BattleContext.SIDE_PLAYER] = false
	_in_contact[BattleContext.SIDE_ENEMY] = false
	for unit in units:
		if unit.is_alive():
			_update_unit(unit, delta)
	_resolve_overlaps()

	if not is_finished():
		_check_victory()
	return events


func _update_unit(unit: BattleUnit, delta: float) -> void:
	unit.cooldown_left = maxf(0.0, unit.cooldown_left - delta)

	var target := _choose_target(unit)
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
		# here rather than being recomputed later by someone else.
		_in_contact[unit.side] = true
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


func _choose_target(unit: BattleUnit) -> BattleUnit:
	var enemy_side := enemy_side_of(unit.side)
	var best: BattleUnit = null
	var best_distance := INF
	for candidate in units:
		if not candidate.is_alive() or candidate.side != enemy_side:
			continue
		var distance := unit.position.distance_to(candidate.position)
		if distance < best_distance:
			best_distance = distance
			best = candidate
	return best


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


## Keeps units from stacking on top of each other. Simple positional relaxation -
## enough to make a formation readable, and the hook a real collision pass would
## replace later.
func _resolve_overlaps() -> void:
	var alive := alive_units()
	for i in alive.size():
		for j in range(i + 1, alive.size()):
			var a := alive[i]
			var b := alive[j]
			var offset := b.position - a.position
			var distance := offset.length()
			var minimum := separation_radius * SEPARATION_FACTOR
			if distance >= minimum:
				continue
			var push := (minimum - distance) * 0.5
			var direction := offset.normalized() if distance > 0.0001 else Vector2.RIGHT
			a.position -= direction * push
			b.position += direction * push


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
