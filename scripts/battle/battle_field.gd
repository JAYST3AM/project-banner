extends "res://scripts/dev/gpu_crowd.gd"

## Campaign adapter for the compute battlefield. The inherited scene remains the
## developer probe when it receives no BattleContext.

var context: BattleContext = null
var config: GameConfig = null
var units: Array[BattleUnit] = []
var winner := ""
var elapsed := 0.0
var _resolved := false


func _ready() -> void:
	context = SceneManager.consume_payload().get("context") as BattleContext
	if context == null:
		DebugLogger.error("battle field opened without a BattleContext", "BattleField")
		SceneManager.change_scene("world_map")
		return
	config = GameManager.config()
	units = BattleSetup.build_units_prepared(context, config)
	if units.is_empty():
		DebugLogger.error("battle field has no combatants", "BattleField")
		SceneManager.change_scene("world_map")
		return
	agents = units.size()
	# The inherited builder uses this only to reserve vertical room for its demo
	# bands; campaign bodies provide their own layout below.
	bodies_per_side = 1
	seed_value = context.terrain_seed
	super._ready()


func _parse_args() -> void:
	# A campaign field is completely described by its BattleContext. The inherited
	# parser is deliberately left untouched for the standalone developer scene.
	if context == null:
		super._parse_args()


func _field_for(_count: int) -> Vector2:
	return BattleSetup.field_size(config)


func _load_unit_stats() -> void:
	_stats.resize(agents * 4)
	for i in agents:
		var unit := units[i]
		_stats[i * 4 + 0] = float(unit.attack)
		_stats[i * 4 + 1] = float(unit.defence)
		_stats[i * 4 + 2] = unit.attack_range
		_stats[i * 4 + 3] = maxf(1.0, unit.attack_cooldown * tick_hz)


func _deploy(state: PackedFloat32Array, meta: PackedFloat32Array, attrs: PackedFloat32Array) -> void:
	var grouped: Dictionary = {}
	for unit in units:
		var key := "%s\u001f%s" % [unit.side, unit.unit_type_id]
		if not grouped.has(key):
			grouped[key] = {"side": unit.side, "members": []}
		var entry := grouped[key] as Dictionary
		var entry_members := entry["members"] as Array
		entry_members.append(unit)

	var groups: Array[Dictionary] = []
	for value in grouped.values():
		groups.append(value as Dictionary)
	groups.sort_custom(_front_to_back_group)

	_bodies = groups.size()
	# Said out loud once: what the campaign handed over, and what this made of it. A campaign field
	# that cannot say these numbers is a field nobody can debug when a battle ends in four ticks.
	var side_counts := {"player": 0, "enemy": 0}
	for unit_of in units:
		side_counts[str(unit_of.side)] = int(side_counts.get(str(unit_of.side), 0)) + 1
	var body_sides: Array[int] = []
	for b_of in groups.size():
		body_sides.append(0 if str((groups[b_of] as Dictionary)["side"]) == BattleContext.SIDE_PLAYER else 1)
	print("battle field: %d men %s | %d bodies, sides %s | sides seen: %s" % [
		units.size(), str(side_counts), _bodies, str(body_sides),
		str(BattleContext.SIDE_PLAYER) + " / " + str(BattleContext.SIDE_ENEMY)])
	_body_side.resize(_bodies)
	_body_state.resize(_bodies * 8)
	_heading.resize(_bodies)
	_order.resize(_bodies)
	_order_target.resize(_bodies)
	_order_point.resize(_bodies)
	_body_alive.resize(_bodies)
	_body_cohesion.resize(_bodies)
	_hold_ordered.resize(_bodies)
	_man_body.resize(agents)
	_man_file.resize(agents)
	_man_rank.resize(agents)

	for b in groups.size():
		var group := groups[b]
		var members := group["members"] as Array
		var side := 0 if str(group["side"]) == BattleContext.SIDE_PLAYER else 1
		_body_side[b] = side
		_order[b] = Order.ENGAGE
		_order_target[b] = -1
		_order_point[b] = Vector2.ZERO
		_hold_ordered[b] = 0
		_body_alive[b] = members.size()
		var anchor := Vector2.ZERO
		for member_value in members:
			anchor += (member_value as BattleUnit).position
		anchor /= float(members.size())
		var files := mini(BODY_FILES, maxi(1, members.size()))
		var ranks := ceili(float(members.size()) / float(files))
		var forward := Vector2.RIGHT if side == 0 else Vector2.LEFT
		_heading[b] = forward.angle()
		_body_state[b * 8 + 0] = anchor.x
		_body_state[b * 8 + 1] = anchor.y
		_body_state[b * 8 + 2] = forward.x
		_body_state[b * 8 + 3] = forward.y
		_body_state[b * 8 + 4] = float(files)
		_body_state[b * 8 + 5] = float(ranks)
		_body_state[b * 8 + 6] = SEPARATION
		_body_state[b * 8 + 7] = 0.0
		for member_index in members.size():
			var unit := members[member_index] as BattleUnit
			var i := unit.id
			state[i * 4 + 0] = unit.position.x
			state[i * 4 + 1] = unit.position.y
			meta[i * 4 + 0] = float(unit.hp)
			meta[i * 4 + 1] = float(side)
			attrs[i * 4 + 0] = float(b)
			attrs[i * 4 + 1] = float(member_index % files)
			attrs[i * 4 + 2] = float(member_index / files)
			_man_body[i] = b
			_man_file[i] = member_index % files
			_man_rank[i] = member_index / files


func _front_to_back_group(left: Dictionary, right: Dictionary) -> bool:
	var left_side := str(left["side"])
	var right_side := str(right["side"])
	if left_side != right_side:
		return left_side == BattleContext.SIDE_PLAYER
	var left_front := _group_front(left["members"] as Array, left_side)
	var right_front := _group_front(right["members"] as Array, right_side)
	return left_front > right_front if left_side == BattleContext.SIDE_PLAYER else left_front < right_front


func _group_front(members: Array, side: String) -> float:
	var front := -INF if side == BattleContext.SIDE_PLAYER else INF
	for member_value in members:
		var x := (member_value as BattleUnit).position.x
		front = maxf(front, x) if side == BattleContext.SIDE_PLAYER else minf(front, x)
	return front


func _process(delta: float) -> void:
	super._process(delta)
	if _resolved:
		return
	elapsed = float(_tick) / maxf(1.0, tick_hz)
	if _tick > 0 and (_alive.x == 0 or _alive.y == 0):
		winner = BattleContext.SIDE_PLAYER if _alive.x > 0 else BattleContext.SIDE_ENEMY if _alive.y > 0 else ""
		_resolve(false)
	elif elapsed >= config.get_float("battle.max_duration_seconds", 600.0):
		_frozen = true
		winner = ""
		_resolve(false)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed and not key_event.echo and key_event.keycode == KEY_R:
			_resolve(true)
			get_viewport().set_input_as_handled()
			return
	super._unhandled_input(event)


func find_unit(id: int) -> BattleUnit:
	if id >= 0 and id < units.size():
		return units[id]
	return null


func _resolve(retreated: bool) -> void:
	if _resolved:
		return
	_resolved = true
	_frozen = true
	_readback_and_pack()
	_write_outcome()
	var state := GameManager.campaign
	var resolver := BattleResolver.build(state, config)
	if resolver != null:
		var result := resolver.build_result(context, self, winner, elapsed, retreated)
		resolver.apply(result, context)
	if retreated:
		var encounters := EncounterService.build(state, config)
		if encounters != null:
			encounters.apply_retreat(state.world_party(context.world_party_id))
	SceneManager.change_scene("world_map", {"select_settlement_id": ""})


func _write_outcome() -> void:
	var state_data := _state_bytes.to_float32_array()
	var meta_data := _meta_bytes.to_float32_array()
	for i in units.size():
		var unit := units[i]
		var record := tally(i)
		unit.alive = meta_data[i * 4 + 2] < 0.5 and meta_data[i * 4] > 0.0
		unit.hp = maxi(0, roundi(meta_data[i * 4]))
		unit.kills = record.x
		unit.damage_dealt = roundi(float(record.y) / 100.0)
		unit.killed_by_id = record.w
		unit.position = Vector2(state_data[i * 4], state_data[i * 4 + 1])
		unit.facing = _forward_of(_man_body[i])
