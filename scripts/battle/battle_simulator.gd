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

var config: GameConfig = null
var rng: RandomNumberGenerator = null

var units: Array[BattleUnit] = []
var state: State = State.DEPLOYING
var elapsed: float = 0.0
var winner: String = ""

## Events produced by the most recent [method step] call. The view consumes them;
## nothing else should depend on their contents surviving a frame.
var events: Array[Dictionary] = []

var field_size: Vector2 = Vector2(100.0, 60.0)
var separation_radius: float = 1.5
var base_hit_chance: float = 0.75
var defence_mitigation: float = 0.05
var max_duration: float = 600.0


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


func add_units(p_units: Array[BattleUnit]) -> void:
	units = p_units


func start() -> void:
	state = State.RUNNING
	elapsed = 0.0


func is_running() -> bool:
	return state == State.RUNNING


func is_finished() -> bool:
	return state == State.FINISHED


func find_unit(unit_id: int) -> BattleUnit:
	for unit in units:
		if unit.id == unit_id:
			return unit
	return null


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
		# In reach: stand and strike rather than walk into the enemy.
		if unit.cooldown_left <= 0.0:
			_attack(unit, target)
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
	unit.position += to_point.normalized() * unit.move_speed * delta
	unit.position = Vector2(
		clampf(unit.position.x, 0.5, field_size.x - 0.5),
		clampf(unit.position.y, 0.5, field_size.y - 0.5)
	)


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
