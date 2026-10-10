class_name BattleCombatRetentionGate
extends RefCounted
## S2's independent CPU oracle for the original simulator's _retained_target
## eligibility predicate. GPU validates this snapshot BEFORE each CPU tick.
## Full automatic search, cadence and mid-tick choices are not covered.
const NONE := 0
const VALID := 1
const MISSING := 2
const ALLY := 3
const DEAD := 4
const FAR := 5
const INACTIVE := 6
const MAX_TICKS := 160
const STEP := 0.05


static func cpu_one(unit: BattleUnit, sim: BattleSimulator) -> PackedInt32Array:
	var answer := PackedInt32Array([-1, NONE, 0, 0])
	if unit == null or not unit.is_alive():
		answer[1] = INACTIVE
		return answer
	if unit.auto_target_id < 0:
		return answer
	var target: BattleUnit = null
	for candidate in sim.units:
		if candidate != null and candidate.id == unit.auto_target_id:
			target = candidate
			break
	if target == null:
		answer[1] = MISSING
	elif target.side == unit.side:
		answer[1] = ALLY
	elif not target.is_alive():
		answer[1] = DEAD
		var reach := unit.attack_range * sim.target_contact_loss_factor
		if sim.target_immediate_on_contact_loss and \
				unit.position.distance_squared_to(target.position) <= reach * reach:
			answer[2] = 1
	else:
		var search := unit.awareness_radius if unit.awareness_radius > 0.0 \
			else sim.target_search_radius
		var radius := maxf(search, sim.target_retention_radius)
		if unit.position.distance_squared_to(target.position) > radius * radius:
			answer[1] = FAR
		else:
			answer[0] = target.id
			answer[1] = VALID
	return answer


static func cpu_all(sim: BattleSimulator) -> PackedInt32Array:
	var result := PackedInt32Array()
	for soldier in sim.units:
		result.append_array(cpu_one(soldier, sim))
	return result


static func compare(expected: PackedInt32Array, observed: PackedInt32Array,
		tick: int, units: Array[BattleUnit]) -> Dictionary:
	if expected.size() != observed.size():
		return {"ok": false, "tick": tick, "field": "retention.output.size",
			"cpu": expected.size(), "gpu": observed.size()}
	var names := ["remembered_id", "reason", "immediate_reacquire", "reserved"]
	for i in expected.size():
		if expected[i] != observed[i]:
			var slot := int(i / 4)
			return {"ok": false, "tick": tick,
				"field": "soldier[%d].retention.%s" % [
					units[slot].id, names[i % 4]],
				"cpu": expected[i], "gpu": observed[i]}
	return {"ok": true}


## Comprehensive deliberately adversarial snapshot: none, missing, ally,
## dead-contact, dead-owner, valid and distant. Not an empty smoke test.
static func fixture() -> BattleSimulator:
	var sim := BattleSimulator.new(GameManager.config(), 73001)
	var soldiers: Array[BattleUnit] = []
	for id in 8:
		var side := BattleContext.SIDE_PLAYER if id < 4 else BattleContext.SIDE_ENEMY
		var unit := BattleCombatEquivalenceGate._soldier(
			id, side, Vector2(float(id) * 2.0 + 10.0, 20.0), -1)
		soldiers.append(unit)
	sim.add_units(soldiers)
	sim.start()
	soldiers[0].auto_target_id = -1
	soldiers[1].auto_target_id = 999
	soldiers[2].auto_target_id = 0
	soldiers[3].auto_target_id = 4
	soldiers[3].position = Vector2(18.0, 20.0)
	soldiers[4].hp = 0
	soldiers[4].alive = false
	soldiers[5].auto_target_id = 0
	soldiers[5].position = Vector2(11.0, 20.0)
	soldiers[6].auto_target_id = 1
	soldiers[6].position = Vector2(95.0, 40.0)
	soldiers[7].hp = 0
	soldiers[7].alive = false
	return sim


static func live(seed_value: int) -> BattleSimulator:
	var sim := BattleCombatEquivalenceGate.scenario(seed_value)
	for unit in sim.units:
		unit.attack_order_target_id = -1
		unit.auto_target_id = unit.id + 2 if unit.id < 2 else unit.id - 2
		unit.next_search_tick = 400
	return sim


static func run_seed(seed_value: int,
		probe: BattleGpuRetentionProbe = null) -> Dictionary:
	var reference := live(seed_value)
	var shadow := live(seed_value)
	var checked := 0
	var gpu_decisions := 0
	var valid_retained := 0
	for tick in range(1, MAX_TICKS + 1):
		if reference.is_finished() and shadow.is_finished():
			break
		var oracle := cpu_all(reference)
		if probe != null:
			var observed := probe.evaluate(shadow)
			if observed.is_empty():
				return {"ok": false, "tick": tick, "field": "gpu.retention.readback",
					"cpu": oracle.size(), "gpu": probe.last_error}
			var verdict := compare(oracle, observed, tick, reference.units)
			if not bool(verdict["ok"]):
				return verdict
			gpu_decisions += reference.units.size()
			for i in reference.units.size():
				if observed[i * 4 + 1] == VALID:
					valid_retained += 1
		var cpu_events := reference.step(STEP)
		var shadow_events := shadow.step(STEP)
		var difference := BattleCombatEquivalenceGate.first_difference(
			BattleCombatEquivalenceGate.trace(reference, cpu_events),
			BattleCombatEquivalenceGate.trace(shadow, shadow_events), tick)
		if not bool(difference["ok"]):
			return difference
		checked += 1
	if not reference.is_finished() or not shadow.is_finished():
		return {"ok": false, "tick": checked, "field": "battle.completion",
			"cpu": reference.state, "gpu": shadow.state}
	var fallen := 0
	for unit in reference.units:
		if not unit.is_alive():
			fallen += 1
	return {"ok": true, "seed": seed_value, "ticks": checked,
		"gpu_decisions": gpu_decisions, "valid_retained": valid_retained,
		"casualties": fallen, "winner": reference.winner}
