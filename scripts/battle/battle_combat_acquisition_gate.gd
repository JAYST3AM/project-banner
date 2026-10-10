class_name BattleCombatAcquisitionGate
extends RefCounted
## Slice 3: independent pre-tick CPU oracle for nearest *eligible* enemy
## and strict squared-distance switching hysteresis. It never invokes
## BattleSimulator's target-selection helpers or changes the battle.
## The GPU proves only this local candidate/threshold decision, not the
## simulator's cadence, focus, retaliation or subsequent target mutations.
const INACTIVE := 0
const NO_TARGET := 1
const ACQUIRE := 2
const KEEP_NEAREST := 3
const KEEP_HYSTERESIS := 4
const SWITCH := 5
const KEEP_NONLOCAL := 6
const EXPLICIT_OVERRIDE := 7
const STEP := 0.05
const MAX_TICKS := 160
const CASES := [
	"tie_low_id", "tie_reverse_roster", "tie_same_position",
	"keep_nearest", "keep_hysteresis", "switch_clearer",
	"switch_below_threshold", "keep_tied_challenger",
	"keep_nonlocal", "no_enemy", "outside_search",
	"explicit_override", "inactive_owner", "dead_cache",
	"awareness_override", "friendly_ignored", "dead_ignored"
]


## Output per soldier is (chosen target, reason, nearest local id,
## valid retained id), all int32. Deliberately independent of GPU logic.
static func cpu_one(sim: BattleSimulator, soldier: BattleUnit) -> PackedInt32Array:
	var result := PackedInt32Array([-1, NO_TARGET, -1, -1])
	if not soldier.is_alive():
		result[1] = INACTIVE
		return result
	if soldier.attack_order_target_id >= 0:
		result[1] = EXPLICIT_OVERRIDE
		return result

	var base_radius := soldier.awareness_radius if soldier.awareness_radius > 0.0 \
		else sim.target_search_radius
	var search_limit := maxf(base_radius, sim.target_search_max_radius)
	var retention_limit := maxf(base_radius, sim.target_retention_radius)
	var chosen: BattleUnit = null
	var closest_sq := INF
	var retained: BattleUnit = null
	var retained_sq := INF
	for contender in sim.units:
		if contender == null or not contender.is_alive() or \
				contender.side == soldier.side:
			continue
		var d2 := soldier.position.distance_squared_to(contender.position)
		if contender.id == soldier.auto_target_id and \
				d2 <= retention_limit * retention_limit:
			retained = contender
			retained_sq = d2
		if d2 > search_limit * search_limit:
			continue
		if chosen == null or d2 < closest_sq or \
				(d2 == closest_sq and contender.id < chosen.id):
			chosen = contender
			closest_sq = d2

	if chosen != null:
		result[2] = chosen.id
	if retained != null:
		result[3] = retained.id
	if chosen == null:
		if retained != null:
			result[0] = retained.id
			result[1] = KEEP_NONLOCAL
	elif retained == null:
		result[0] = chosen.id
		result[1] = ACQUIRE
	elif chosen.id == retained.id:
		result[0] = retained.id
		result[1] = KEEP_NEAREST
	elif closest_sq * sim.target_switch_advantage * \
			sim.target_switch_advantage < retained_sq:
		result[0] = chosen.id
		result[1] = SWITCH
	else:
		result[0] = retained.id
		result[1] = KEEP_HYSTERESIS
	return result


static func cpu_all(sim: BattleSimulator) -> PackedInt32Array:
	var all := PackedInt32Array()
	for unit in sim.units:
		all.append_array(cpu_one(sim, unit))
	return all


## The FIRST different integer is returned with exact soldier identity,
## subfield, tick and expected/actual values; no mismatch count shortcut.
static func compare(expected: PackedInt32Array, observed: PackedInt32Array,
		tick: int, roster: Array[BattleUnit]) -> Dictionary:
	if expected.size() != observed.size():
		return {"ok": false, "tick": tick, "field": "acquisition.output.size",
			"cpu": expected.size(), "gpu": observed.size()}
	var fields := ["chosen_id", "reason", "nearest_id", "retained_id"]
	for i in expected.size():
		if expected[i] != observed[i]:
			var slot := int(i / 4)
			if slot >= roster.size():
				return {"ok": false, "tick": tick,
					"field": "acquisition.unexpected_output[%d]" % i,
					"cpu": expected[i], "gpu": observed[i]}
			return {"ok": false, "tick": tick,
				"field": "soldier[%d].acquisition.%s" % [
					roster[slot].id, fields[i % 4]],
				"cpu": expected[i], "gpu": observed[i]}
	return {"ok": true}


## Each static fixture is an independent simulator with live/dead allies,
## two equidistant enemies, a cached challenger, and explicit case changes.
## The low-id enemy is intentionally listed AFTER its equal-distance rival
## in the default roster, so a first-hit search fails the tie test.
static func fixture(kind: String) -> BattleSimulator:
	var sim := BattleSimulator.new(GameManager.config(), 73001)
	var actor := BattleCombatEquivalenceGate._soldier(
		10, BattleContext.SIDE_PLAYER, Vector2(50.0, 50.0), -1)
	var ally := BattleCombatEquivalenceGate._soldier(
		2, BattleContext.SIDE_PLAYER, Vector2(50.5, 50.0), -1)
	var enemy_high := BattleCombatEquivalenceGate._soldier(
		30, BattleContext.SIDE_ENEMY, Vector2(50.0, 54.0), -1)
	var enemy_low := BattleCombatEquivalenceGate._soldier(
		20, BattleContext.SIDE_ENEMY, Vector2(54.0, 50.0), -1)
	var held := BattleCombatEquivalenceGate._soldier(
		40, BattleContext.SIDE_ENEMY, Vector2(55.0, 50.0), -1)
	var dead := BattleCombatEquivalenceGate._soldier(
		5, BattleContext.SIDE_ENEMY, Vector2(50.0, 50.1), -1)
	dead.hp = 0
	dead.alive = false
	var roster: Array[BattleUnit] = [actor, ally, enemy_high, enemy_low, held, dead]
	if kind == "tie_reverse_roster":
		roster = [actor, ally, enemy_low, enemy_high, held, dead]
	sim.add_units(roster)
	sim.start()
	actor.auto_target_id = -1
	match kind:
		"tie_same_position":
			enemy_high.position = enemy_low.position
		"keep_nearest":
			actor.auto_target_id = 20
		"keep_hysteresis":
			actor.auto_target_id = 40
		"switch_clearer":
			actor.auto_target_id = 40
			held.position = Vector2(58.0, 50.0)
		"switch_below_threshold":
			actor.auto_target_id = 40
			sim.target_switch_advantage = 1.24
		"keep_tied_challenger":
			actor.auto_target_id = 30
		"keep_nonlocal":
			actor.auto_target_id = 40
			sim.target_search_radius = 3.0
			sim.target_search_max_radius = 3.0
			sim.target_retention_radius = 9.0
		"no_enemy":
			enemy_high.hp = 0
			enemy_high.alive = false
			enemy_low.hp = 0
			enemy_low.alive = false
			held.hp = 0
			held.alive = false
		"outside_search":
			sim.target_search_radius = 2.0
			sim.target_search_max_radius = 2.0
		"explicit_override":
			actor.attack_order_target_id = 20
		"inactive_owner":
			actor.hp = 0
			actor.alive = false
		"dead_cache":
			actor.auto_target_id = 40
			held.hp = 0
			held.alive = false
		"awareness_override":
			sim.target_search_radius = 2.0
			sim.target_search_max_radius = 2.0
			actor.awareness_radius = 5.0
		"friendly_ignored":
			ally.position = Vector2(50.05, 50.0)
		"dead_ignored":
			dead.position = Vector2(50.0, 50.0)
	return sim


## Expected first soldier decisions for every fixture, including all
## reason codes and both roster-order/equal-position tie-break paths.
static func expected_for(kind: String) -> PackedInt32Array:
	match kind:
		"tie_low_id", "tie_reverse_roster", "tie_same_position", \
		"dead_cache", "awareness_override", "friendly_ignored", \
		"dead_ignored":
			return PackedInt32Array([20, ACQUIRE, 20, -1])
		"keep_nearest":
			return PackedInt32Array([20, KEEP_NEAREST, 20, 20])
		"keep_hysteresis":
			return PackedInt32Array([40, KEEP_HYSTERESIS, 20, 40])
		"switch_clearer", "switch_below_threshold":
			return PackedInt32Array([20, SWITCH, 20, 40])
		"keep_tied_challenger":
			return PackedInt32Array([30, KEEP_HYSTERESIS, 20, 30])
		"keep_nonlocal":
			return PackedInt32Array([40, KEEP_NONLOCAL, -1, 40])
		"explicit_override":
			return PackedInt32Array([-1, EXPLICIT_OVERRIDE, -1, -1])
		"inactive_owner":
			return PackedInt32Array([-1, INACTIVE, -1, -1])
		_:
			return PackedInt32Array([-1, NO_TARGET, -1, -1])


## Real fixed-seed CPU fights; remove explicit orders and stagger cached
## targets so independent GPU acquisition and switches are both exercised.
static func live(seed: int) -> BattleSimulator:
	var sim := BattleCombatRetentionGate.live(seed)
	sim.units[0].auto_target_id = 3
	sim.units[1].auto_target_id = -1
	sim.units[2].auto_target_id = 1
	sim.units[3].auto_target_id = -1
	return sim


static func run_seed(seed: int, probe: BattleGpuAcquisitionProbe = null) -> Dictionary:
	var cpu := live(seed)
	var shadow := live(seed)
	var checks := 0
	var decisions := 0
	var acquired := 0
	var switched := 0
	for tick in range(1, MAX_TICKS + 1):
		if cpu.is_finished() and shadow.is_finished():
			break
		var reference := cpu_all(cpu)
		if probe != null:
			var gpu := probe.evaluate(shadow)
			if gpu.is_empty():
				return {"ok": false, "tick": tick,
					"field": "gpu.acquisition.readback",
					"cpu": reference.size(), "gpu": probe.last_error}
			var first := compare(reference, gpu, tick, cpu.units)
			if not bool(first["ok"]):
				return first
			decisions += cpu.units.size()
			for i in cpu.units.size():
				var reason := gpu[i * 4 + 1]
				if reason == ACQUIRE:
					acquired += 1
				elif reason == SWITCH:
					switched += 1
		var events_cpu := cpu.step(STEP)
		var events_shadow := shadow.step(STEP)
		var mismatch := BattleCombatEquivalenceGate.first_difference(
			BattleCombatEquivalenceGate.trace(cpu, events_cpu),
			BattleCombatEquivalenceGate.trace(shadow, events_shadow), tick)
		if not bool(mismatch["ok"]):
			return mismatch
		checks += 1
	if not cpu.is_finished() or not shadow.is_finished():
		return {"ok": false, "tick": checks,
			"field": "battle.completion", "cpu": cpu.state, "gpu": shadow.state}
	var casualties := 0
	for unit in cpu.units:
		if not unit.is_alive():
			casualties += 1
	return {"ok": true, "seed": seed, "ticks": checks,
		"gpu_decisions": decisions, "acquisitions": acquired,
		"switches": switched, "casualties": casualties, "winner": cpu.winner}
