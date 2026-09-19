extends "res://scripts/dev/gpu_crowd.gd"

## Campaign adapter for the compute battlefield. The inherited scene remains the
## developer probe when it receives no BattleContext.
##
## [b]A battle from the command line.[/b] With no context and `--side=archer:15,spearman:30` (and
## `--theirs=` for a different enemy army) the field builds a synthetic roster of that composition
## for both sides and fights it: the same deployment, stats, sprites and arrows as a campaign
## battle, assembled from the unit catalogue instead of from a world party. A real battle always
## carries a context, so this cannot reach one - it is how a battle of a given shape gets looked at
## without a campaign to walk to it.

const SIDE_FLAG := "--side="
const THEIRS_FLAG := "--theirs="

var context: BattleContext = null
var config: GameConfig = null
var units: Array[BattleUnit] = []
var winner := ""
var elapsed := 0.0
## True when the roster came from the command line rather than from a campaign.
var synthetic := false
var _composition: Array[Dictionary] = []
var _enemy_composition: Array[Dictionary] = []
var _resolved := false


func _ready() -> void:
	context = SceneManager.consume_payload().get("context") as BattleContext
	_parse_composition()
	if context == null and _composition.is_empty():
		DebugLogger.error("battle field opened without a BattleContext", "BattleField")
		SceneManager.change_scene("world_map")
		return
	config = GameManager.config()
	if context == null:
		synthetic = true
		context = _synthetic_context()
		units = _synthetic_units()
		# The probe's own knobs - ticks a frame, the seed - are read when the scene runs
		# standalone; [method _parse_args] is what routes them here.
		_parse_args()
		agents = units.size()
	else:
		units = BattleSetup.build_units_prepared(context, config)
	if units.is_empty():
		DebugLogger.error("battle field has no combatants", "BattleField")
		SceneManager.change_scene("world_map")
		return
	agents = units.size()
	var ours := 0
	var theirs := 0
	for unit_of in units:
		if unit_of.side == BattleContext.SIDE_PLAYER:
			ours += 1
		else:
			theirs += 1
	DebugLogger.info("battle %s: %d of ours against %d of theirs, seed %d, ground %s" % [
		context.battle_id, ours, theirs, context.battle_seed, context.weather], "BattleField")
	# The inherited builder uses this only to reserve vertical room for its demo
	# bands; campaign bodies provide their own layout below.
	bodies_per_side = 1
	seed_value = context.terrain_seed
	super._ready()
	# The journal's second line, and the one a demo battle is read for: who took the field, by
	# type. A buffer has no unit types in it - this is the only place that knows them.
	var counts := {}
	for unit_of in units:
		var key := "%s %s" % [unit_of.side, unit_of.unit_type_id]
		counts[key] = int(counts.get(key, 0)) + 1
	if not counts.is_empty():
		var parts: Array = []
		for key in counts.keys():
			parts.append("%s x%d" % [key, counts[key]])
		parts.sort()
		journal_note("the roster: %s" % ", ".join(parts))


## Read `--side=` and `--theirs=` into type-and-count lists, dropping anything the catalogue does
## not have - out loud, because a silently empty army is a mystery rather than a short demo.
func _parse_composition() -> void:
	var catalog := UnitCatalog.load_from()
	for arg in OS.get_cmdline_user_args():
		var target := _composition
		var text := ""
		if arg.begins_with(SIDE_FLAG):
			text = arg.substr(SIDE_FLAG.length())
		elif arg.begins_with(THEIRS_FLAG):
			target = _enemy_composition
			text = arg.substr(THEIRS_FLAG.length())
		else:
			continue
		for part in text.split(",", false):
			var bits := part.split(":")
			if bits.size() != 2:
				continue
			var type_id := bits[0].strip_edges()
			var count := int(bits[1])
			if count <= 0 or not catalog.has(type_id):
				print("battle field: %s ignores %s (the catalogue has: %s)" % [
					arg.get_slice("=", 0), part, ", ".join(catalog.ids())])
				continue
			target.append({"type": type_id, "count": count})
	if not _composition.is_empty() and _enemy_composition.is_empty():
		_enemy_composition = _composition.duplicate(true)


## The context a demo battle runs under: the ids and seeds the scene expects and no world party.
func _synthetic_context() -> BattleContext:
	var made := BattleContext.new()
	made.battle_id = "demo"
	made.battle_seed = seed_value if seed_value > 0 else 2026
	made.terrain_seed = made.battle_seed
	made.enemy_display_name = "Demo Enemy"
	made.weather = "clear"
	return made


## The roster a demo battle fields: every man built from the catalogue's definition for his type,
## and positioned by the campaign's own [method BattleSetup.deploy] - melee to the front, ranged
## behind, in ranks that fit the deployment depth.
func _synthetic_units() -> Array[BattleUnit]:
	var catalog := UnitCatalog.load_from()
	var built: Array[BattleUnit] = []
	var next_id := 0
	for side in [BattleContext.SIDE_PLAYER, BattleContext.SIDE_ENEMY]:
		var composition: Array[Dictionary] = _composition \
			if side == BattleContext.SIDE_PLAYER else _enemy_composition
		for entry in composition:
			var definition := catalog.get_definition(str(entry["type"]))
			for i in int(entry["count"]):
				built.append(BattleUnit.from_snapshot(_snapshot(definition, next_id), side, next_id))
				next_id += 1
	BattleSetup.deploy(built, config)
	return built


## One man's snapshot, in the shape [method BattleUnit.from_snapshot] reads: the definition's own
## numbers at level one, no traits. A demo soldier is nobody's persistent person.
func _snapshot(definition: UnitDefinition, id: int) -> Dictionary:
	var hp := definition.max_hp_at(1, config)
	return {
		"soldier_id": "demo_%d" % id,
		"name": "%s %d" % [definition.display_name, id + 1],
		"unit_type_id": definition.id,
		"unit_name": definition.display_name,
		"level": 1,
		"max_hp": hp,
		"hp": hp,
		"attack": definition.attack_at(1, config),
		"defence": definition.defence,
		"move_speed": definition.move_speed,
		"attack_range": definition.attack_range,
		"attack_cooldown": definition.attack_cooldown,
		"ranged": definition.ranged,
		"traits": [],
	}


func _parse_args() -> void:
	# A campaign field is completely described by its BattleContext. The inherited parser is
	# deliberately left untouched for the standalone developer scene - and for a synthetic roster,
	# whose knobs (--ticks-per-frame, --seed, --rule-checks) come from the same place.
	if context == null or synthetic:
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
	# Who shoots: the roster's own ranged flag, which is what the agent sim's per-man attack range
	# already came from - this is the same fact told to the picture.
	_man_ranged.resize(agents)
	_man_ranged.fill(0)

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
			_man_ranged[i] = 1 if unit.ranged else 0


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
	if synthetic:
		# A demo battle has no campaign to write an outcome to: it freezes where it is and stays on
		# the screen, which is the whole point of looking at it. One line, and the bounds - so a
		# demo that ended says where everybody finished.
		if _resolved:
			return
		_resolved = true
		_frozen = true
		_report_bounds()
		return
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


## Where everybody stands, dead and alive, against the field they are supposed to be inside. The
## owner watched fallen markers drift off the drawn ground; every write path in the shader clamps to
## the field, so either this says men are outside it - and the clamp is a lie - or it says they are
## inside it, and the fault is in what gets drawn where.
func _report_bounds() -> void:
	var alive_lo := Vector2(INF, INF)
	var alive_hi := Vector2(-INF, -INF)
	var dead_lo := Vector2(INF, INF)
	var dead_hi := Vector2(-INF, -INF)
	var alive_n := 0
	var dead_n := 0
	for unit in units:
		if unit.is_alive():
			alive_lo = alive_lo.min(unit.position)
			alive_hi = alive_hi.max(unit.position)
			alive_n += 1
		else:
			dead_lo = dead_lo.min(unit.position)
			dead_hi = dead_hi.max(unit.position)
			dead_n += 1
	print("battle field: bounds | field (%.1f, %.1f) | alive %d x %.1f..%.1f y %.1f..%.1f | dead %d x %.1f..%.1f y %.1f..%.1f" % [
		field.x, field.y, alive_n, alive_lo.x, alive_hi.x, alive_lo.y, alive_hi.y,
		dead_n, dead_lo.x, dead_hi.x, dead_lo.y, dead_hi.y])
	# The same reading as one log line, with a verdict on whether anyone is outside the field they
	# are supposed to be inside - the owner's off-map markers in one grep.
	var outside := 0
	for unit_of in units:
		if unit_of.position.x < 0.0 or unit_of.position.x > field.x or unit_of.position.y < 0.0 or unit_of.position.y > field.y:
			outside += 1
	DebugLogger.info("outcome written: %d alive, %d fallen, %d outside the field (%.0f x %.0f)" % [
		alive_n, dead_n, outside, field.x, field.y], "BattleField")


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
	# After the writeback, not before: the units carry the battle's positions from here, and a
	# report taken before it was a report of the deployment. That mistake cost a run too.
	_report_bounds()
