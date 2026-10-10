class_name BattleCombatEquivalenceGate
extends RefCounted
## First GPU combat equivalence gate. Production BattleSimulator is run twice:
## reference CPU and independent CPU shadow. The GPU computes exactly ONE
## decision independently: validity of an explicit ordered target for each
## soldier, BEFORE that tick is advanced. Both simulators still use their CPU
## result, never the GPU output. Other combat stages are NOT GPU-equivalent.
const SEEDS := [101, 2026, 4096, 73001]
const TICK_SECONDS := 0.05
const MAX_TICKS := 160


static func _soldier(id: int, side: String, point: Vector2, target: int) -> BattleUnit:
	var soldier := BattleUnit.new()
	soldier.id = id
	soldier.side = side
	soldier.soldier_id = "eq_soldier_%d" % id
	soldier.display_name = "Equivalence %d" % id
	soldier.unit_type_id = "spearman"
	soldier.max_hp = 10
	soldier.hp = 10
	soldier.attack = 14
	soldier.defence = 0
	soldier.move_speed = 0.1
	soldier.attack_range = 4.0
	soldier.attack_cooldown = 0.10
	soldier.position = point
	soldier.attack_order_target_id = target
	return soldier


## Same FOUR individuals and explicit orders, independently allocated per run.
static func scenario(seed_value: int) -> BattleSimulator:
	var sim := BattleSimulator.new(GameManager.config(), seed_value)
	var units: Array[BattleUnit] = [
		_soldier(0, BattleContext.SIDE_PLAYER, Vector2(40.0, 23.0), 2),
		_soldier(1, BattleContext.SIDE_PLAYER, Vector2(40.0, 31.0), 3),
		_soldier(2, BattleContext.SIDE_ENEMY, Vector2(41.0, 23.0), 0),
		_soldier(3, BattleContext.SIDE_ENEMY, Vector2(41.0, 31.0), 1),
	]
	sim.add_units(units)
	sim.max_duration = 6.0
	sim.start()
	return sim


## This is the CPU simulator's priority-1 explicit-order semantics, independent
## of the shader. Unordered search/retaliation is deliberately outside slice 1.
static func cpu_explicit_target(unit: BattleUnit,
		roster: Array[BattleUnit]) -> int:
	if unit == null or not unit.is_alive() or unit.attack_order_target_id < 0:
		return -1
	for other in roster:
		if other != null and other.id == unit.attack_order_target_id and \
				other.is_alive() and other.side != unit.side:
			return other.id
	return -1


static func cpu_ordered_targets(roster: Array[BattleUnit]) -> PackedInt32Array:
	var answers := PackedInt32Array()
	for unit in roster:
		answers.append(cpu_explicit_target(unit, roster))
	return answers


static func _field(name: String, value: Variant) -> Dictionary:
	return {"field": name, "value": value}


## A stable ordered trace: reporting a first mismatch is more useful than
## hashing all the state and discovering it differed somewhere.
static func trace(sim: BattleSimulator, events: Array[Dictionary]) -> Array[Dictionary]:
	var rows: Array[Dictionary] = [
		_field("battle.state", sim.state),
		_field("battle.winner", sim.winner),
		_field("battle.tick", sim.tick_index),
		_field("battle.elapsed", sim.elapsed),
		_field("battle.player_alive", sim.side_count(BattleContext.SIDE_PLAYER)),
		_field("battle.enemy_alive", sim.side_count(BattleContext.SIDE_ENEMY)),
	]
	for i in sim.units.size():
		var soldier: BattleUnit = sim.units[i]
		var p := "soldier[%d]." % i
		rows.append(_field(p + "id", soldier.id))
		rows.append(_field(p + "identity", soldier.soldier_id))
		rows.append(_field(p + "side", soldier.side))
		rows.append(_field(p + "alive", soldier.is_alive()))
		rows.append(_field(p + "hp", soldier.hp))
		rows.append(_field(p + "target.explicit_order", soldier.attack_order_target_id))
		rows.append(_field(p + "target.retained_auto", soldier.auto_target_id))
		rows.append(_field(p + "target.last_attacker", soldier.last_attacker_id))
		rows.append(_field(p + "kills", soldier.kills))
		rows.append(_field(p + "damage_dealt", soldier.damage_dealt))
		rows.append(_field(p + "damage_taken", soldier.damage_taken))
		rows.append(_field(p + "killed_by", soldier.killed_by_id))
		rows.append(_field(p + "position", soldier.position))
		rows.append(_field(p + "facing", soldier.facing))
		rows.append(_field(p + "cooldown", soldier.cooldown_left))
	rows.append(_field("events.count", events.size()))
	var event_keys := ["type", "attacker", "target", "damage", "killed",
		"unit", "soldier_id", "killer", "side", "ranged"]
	for i in events.size():
		var event := events[i]
		for key in event_keys:
			rows.append(_field("events[%d].%s" % [i, key],
				event.get(key, null)))
	return rows


## Returns the FIRST divergent path, without suppressing missing fields.
static func first_difference(expected: Array[Dictionary],
		actual: Array[Dictionary], tick: int) -> Dictionary:
	if expected.size() != actual.size():
		return {"ok": false, "tick": tick, "field": "trace.field_count",
			"cpu": expected.size(), "gpu": actual.size()}
	for i in expected.size():
		if expected[i]["field"] != actual[i]["field"]:
			return {"ok": false, "tick": tick, "field": "trace.field_name[%d]" % i,
				"cpu": expected[i]["field"], "gpu": actual[i]["field"]}
		if expected[i]["value"] != actual[i]["value"]:
			return {"ok": false, "tick": tick, "field": expected[i]["field"],
				"cpu": expected[i]["value"], "gpu": actual[i]["value"]}
	return {"ok": true}


static func _target_difference(reference: PackedInt32Array,
		proposed: PackedInt32Array, tick: int) -> Dictionary:
	if reference.size() != proposed.size():
		return {"ok": false, "tick": tick, "field": "target.count",
			"cpu": reference.size(), "gpu": proposed.size()}
	for i in reference.size():
		if reference[i] != proposed[i]:
			return {"ok": false, "tick": tick,
				"field": "soldier[%d].target.explicit_validated" % i,
				"cpu": reference[i], "gpu": proposed[i]}
	return {"ok": true}


## A GPU probe is mandatory for a GPU certification run. Passing null is
## permitted ONLY for fast headless CPU-oracle and comparator tests.
static func run_seed(seed_value: int,
		probe: BattleGpuOrderedTargetProbe = null) -> Dictionary:
	var cpu := scenario(seed_value)
	var shadow := scenario(seed_value)
	var checked := 0
	var target_checks := 0
	for tick in range(1, MAX_TICKS + 1):
		if cpu.is_finished() and shadow.is_finished():
			break
		# Each tick's independently computed GPU candidate must agree with
		# CPU's actual explicit-order priority rule before anyone moves.
		var cpu_targets := cpu_ordered_targets(cpu.units)
		if probe != null:
			var candidate := probe.evaluate(shadow.units)
			if candidate.is_empty():
				return {"ok": false, "tick": tick,
					"field": "gpu.readback", "cpu": cpu_targets,
					"gpu": probe.last_error}
			var target_difference := _target_difference(cpu_targets, candidate, tick)
			if not bool(target_difference["ok"]):
				return target_difference
			target_checks += candidate.size()
		# A separate CPU shadow preserves authoritative outcomes. GPU
		# decisions are OBSERVED, not adopted. This is intentionally NOT a
		# claim that the shader implements target search, damage, or victory.
		var cpu_events := cpu.step(TICK_SECONDS)
		var shadow_events := shadow.step(TICK_SECONDS)
		var mismatch := first_difference(trace(cpu, cpu_events),
			trace(shadow, shadow_events), tick)
		if not bool(mismatch["ok"]):
			return mismatch
		checked += 1
	if not cpu.is_finished() or not shadow.is_finished():
		return {"ok": false, "tick": checked,
			"field": "battle.completion", "cpu": cpu.state,
			"gpu": shadow.state}
	var killed := 0
	for unit in cpu.units:
		if not unit.is_alive():
			killed += 1
	return {"ok": true, "seed": seed_value, "ticks": checked,
		"target_checks": target_checks, "winner": cpu.winner,
		"casualties": killed, "gpu_targeting_scope": "explicit_orders_only"}
