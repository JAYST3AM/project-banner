extends Node
## Step 7.9 (native soldier batch) - equivalence and cost, on live battles.
##
## [b]What this measures.[/b] The awareness slice of the per-soldier loop, in three shapes, over
## the state of a real running battle rather than a synthetic one:
##
##   1. the sim's own rules, called on a sample of soldiers (`_retained_target` and
##      `_formation_driven_search_allowed`), so the kernel's *decisions* can be compared against
##      the authority they mirror rather than against another copy of my own arithmetic;
##   2. a GDScript mirror of the same decision, run over the identical arrays the kernel is handed,
##      element by element, so the kernel's *loops, pool and partitioning* are compared against
##      code that is obviously the same rule;
##   3. the kernel itself, at one worker and at the machine's default.
##
## Disagreements in either comparison are the thing this scene exists to find. Cost is reported
## per stage - the boundary (building the arrays), the kernel's own pass, and the GDScript cost of
## the same decisions - because Step 7.7 established that the boundary is often the real bill.
##
## Run: godotc --headless --path . res://scenes/dev/soldier_batch_bench.tscn -- --sizes=600,20000

const TICK := 0.05

var _sizes: Array[int] = [600, 20000]
var _ticks := 12
var _warmup := 160
var _seed := 780780


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--sizes="):
			_sizes = []
			for part in arg.split("=", true, 1)[1].split(",", false):
				_sizes.append(int(part))
		elif arg.begins_with("--ticks="):
			_ticks = int(arg.split("=", true, 1)[1])
		elif arg.begins_with("--warmup="):
			_warmup = int(arg.split("=", true, 1)[1])
		elif arg.begins_with("--seed="):
			_seed = int(arg.split("=", true, 1)[1])
	_show_pool_determinism()
	print("")
	print("=== NATIVE SOLDIER BATCH: equivalence and cost, live battles, seed %d ===" % _seed)
	print("%9s | %8s | %8s | %10s | %10s | %10s | %10s | %8s | %8s | %8s | %s" % [
		"soldiers", "workers", "blocks", "arrays us", "native us", "1 worker", "gdscript", "speedup",
		"rules", "arrays", "decisions keep/hold/defer/search/none"])
	print("-".repeat(150))
	for per_side in _sizes:
		_run_size(per_side)
	print("")
	print("=== COMPLETE ===")
	get_tree().quit()


## The pool's own determinism, asserted rather than assumed: the same batch summed at one worker
## and at the machine's default must agree bit for bit.
func _show_pool_determinism() -> void:
	var one := NativeSoldierBatch.new()
	one.setup(200000, 1, 32.0)
	var many := NativeSoldierBatch.new()
	many.setup(200000, 0, 32.0)
	var first := one.probe_parallel_sum(200000)
	var second := many.probe_parallel_sum(200000)
	var identical: bool = first[0] == second[0]
	print("=== pool determinism: 1 worker %.6f, %d workers %.6f, identical: %s ===" % [
		first[0], int(second[2]), second[0], "yes" if identical else "NO - BUG"])
	# RefCounted: dropping the last reference is the release.
	one = null
	many = null


func _run_size(per_side: int) -> void:
	var config := GameManager.config()
	var showcase := ShowcaseBattle.build(
		config, UnitCatalog.load_from(), FormationCatalog.load_from(), per_side, _seed)
	var simulator: BattleSimulator = showcase["simulator"]
	# One AI object drives both sides: the commander in this project is deliberately small.
	var ai := BattleAI.new()
	for i in _warmup:
		if simulator.is_finished():
			break
		ai.update(simulator, TICK)
		simulator.step(TICK)

	var count := simulator.units.size()
	var slot_of := {}
	for slot in count:
		slot_of[(simulator.units[slot] as BattleUnit).id] = slot

	var native_batch := NativeSoldierBatch.new()
	native_batch.setup(count, 0, simulator.target_retention_radius)
	var single := NativeSoldierBatch.new()
	single.setup(count, 1, simulator.target_retention_radius)

	var arrays_us := 0
	var native_us := 0
	var single_us := 0
	var reference_us := 0
	var rule_samples := 0
	var rule_disagreements := 0
	var array_disagreements := 0
	var mixes := [0, 0, 0, 0, 0]
	var measured := 0
	var workers := native_batch.worker_count()
	var blocks := 0

	for tick in _ticks:
		if simulator.is_finished():
			break
		measured += 1

		# 1. The boundary: one pass over the soldiers, building the arrays the kernel is handed.
		var started := Time.get_ticks_usec()
		var arrays := _build_arrays(simulator, slot_of)
		arrays_us += Time.get_ticks_usec() - started

		# 3. The kernel, at the machine's default and at one worker.
		started = Time.get_ticks_usec()
		var decisions: PackedInt32Array = native_batch.run_awareness(
			arrays["positions"], arrays["alive"], arrays["sides"], arrays["targets"],
			arrays["reach"], arrays["due"], arrays["struck"], arrays["bodies"],
			arrays["bands"], arrays["boxes"], arrays["box_counts"], arrays["box_offsets"])
		native_us += Time.get_ticks_usec() - started
		blocks = int(native_batch.stats()["blocks"])

		started = Time.get_ticks_usec()
		single.run_awareness(
			arrays["positions"], arrays["alive"], arrays["sides"], arrays["targets"],
			arrays["reach"], arrays["due"], arrays["struck"], arrays["bodies"],
			arrays["bands"], arrays["boxes"], arrays["box_counts"], arrays["box_offsets"])
		single_us += Time.get_ticks_usec() - started

		# 4. The mirror: the same decision, in GDScript, over the same arrays.
		started = Time.get_ticks_usec()
		var reference := _reference_decisions(arrays)
		reference_us += Time.get_ticks_usec() - started

		# 5. The authority: the sim's own functions, on every twentieth soldier. This mutates the
		#    bookkeeping exactly as a real tick does, so it runs after every decision above was
		#    taken and before the tick is stepped - all three answers are about one state.
		var samples := _rule_agreement(simulator, arrays, decisions)
		rule_samples += samples["sampled"]
		rule_disagreements += samples["disagreements"]

		for slot in count:
			var decision := decisions[slot]
			if decision != reference[slot]:
				array_disagreements += 1
			mixes[decision] += 1

		ai.update(simulator, TICK)
		simulator.step(TICK)

	var speedup := 0.0 if native_us == 0 else float(reference_us) / float(native_us)
	print("%9d | %8d | %8d | %10.1f | %10.1f | %10.1f | %10.1f | %7.2fx | %8d | %8d | %d/%d/%d/%d/%d" % [
		count, workers, blocks,
		float(arrays_us) / measured, float(native_us) / measured, float(single_us) / measured,
		float(reference_us) / measured, speedup,
		rule_disagreements, array_disagreements,
		mixes[1], mixes[2], mixes[3], mixes[4], mixes[0]])
	if rule_samples > 0:
		print("          rule check: %d soldiers sampled against the sim's own functions, %d disagreements" % [
			rule_samples, rule_disagreements])
	native_batch = null
	single = null


## The decision the sim itself would make, taken from the sim's own functions for a sample.
func _rule_agreement(
		simulator: BattleSimulator,
		arrays: Dictionary,
		decisions: PackedInt32Array
) -> Dictionary:
	var sampled := 0
	var disagreements := 0
	for slot in range(0, simulator.units.size(), 20):
		var unit: BattleUnit = simulator.units[slot]
		if unit.attack_order_target_id >= 0:
			continue
		sampled += 1
		var expected := _decision_from_the_sim(simulator, unit)
		if expected != decisions[slot]:
			disagreements += 1
	return {"sampled": sampled, "disagreements": disagreements}


## The sim's own answer for one soldier, in the kernel's vocabulary.
func _decision_from_the_sim(simulator: BattleSimulator, unit: BattleUnit) -> int:
	if not unit.is_alive():
		return NativeSoldierBatch.DECISION_NONE
	var retained: BattleUnit = simulator.call("_retained_target", unit)
	if retained != null:
		var reach := unit.attack_range
		if unit.position.distance_squared_to(retained.position) <= reach * reach:
			return NativeSoldierBatch.DECISION_KEEP
		return NativeSoldierBatch.DECISION_HOLD
	if simulator.tick_index < unit.next_search_tick:
		return NativeSoldierBatch.DECISION_NONE
	if bool(simulator.call("_formation_driven_search_allowed", unit)):
		return NativeSoldierBatch.DECISION_SEARCH
	return NativeSoldierBatch.DECISION_DEFER


func _build_arrays(simulator: BattleSimulator, slot_of: Dictionary) -> Dictionary:
	var count := simulator.units.size()
	var positions := PackedFloat32Array()
	positions.resize(count * 2)
	var alive := PackedInt32Array()
	alive.resize(count)
	var sides := PackedInt32Array()
	sides.resize(count)
	var targets := PackedInt32Array()
	targets.resize(count)
	var reach := PackedFloat32Array()
	reach.resize(count)
	var due := PackedInt32Array()
	due.resize(count)
	var struck := PackedInt32Array()
	struck.resize(count)
	var bodies := PackedInt32Array()
	bodies.resize(count)
	for slot in count:
		var unit: BattleUnit = simulator.units[slot]
		positions[slot * 2] = unit.position.x
		positions[slot * 2 + 1] = unit.position.y
		alive[slot] = 1 if unit.is_alive() else 0
		sides[slot] = 0 if unit.side == BattleContext.SIDE_PLAYER else 1
		reach[slot] = unit.attack_range
		var remembered: int = slot_of.get(unit.auto_target_id, -1)
		targets[slot] = remembered if unit.auto_target_id >= 0 else -1
		if unit.attack_order_target_id >= 0:
			# An ordered soldier never reaches this pass: the sim resolves its order first.
			due[slot] = 0
			struck[slot] = 0
		else:
			due[slot] = 1 if simulator.tick_index >= unit.next_search_tick else 0
			var recent := simulator.tick_index - unit.last_attacked_tick
			struck[slot] = 1 if (unit.last_attacked_tick >= 0 and
				recent <= simulator.retaliation_ticks) else 0
		var body := unit.formation_ref
		bodies[slot] = -1 if body == null else body.index

	var body_slots := 0
	for body in simulator.formations:
		body_slots = maxi(body_slots, body.index + 1)
	var bands := PackedFloat32Array()
	bands.resize(body_slots)
	var box_counts := PackedInt32Array()
	box_counts.resize(body_slots)
	var box_offsets := PackedInt32Array()
	box_offsets.resize(body_slots)
	var boxes := PackedFloat32Array()
	for body in simulator.formations:
		bands[body.index] = body.contact_band
		box_offsets[body.index] = boxes.size() / 4
		var here := 0
		for enemy_id in body.nearby_enemy_ids:
			var enemy: BattleFormation = simulator.formation(enemy_id)
			if enemy == null:
				continue
			boxes.append(enemy.bounds_min.x)
			boxes.append(enemy.bounds_min.y)
			boxes.append(enemy.bounds_max.x)
			boxes.append(enemy.bounds_max.y)
			here += 1
		box_counts[body.index] = here
	return {
		"retention_sq": simulator.target_retention_radius * simulator.target_retention_radius,
		"positions": positions, "alive": alive, "sides": sides, "targets": targets,
		"reach": reach, "due": due, "struck": struck, "bodies": bodies, "bands": bands,
		"boxes": boxes, "box_counts": box_counts, "box_offsets": box_offsets,
	}


## The mirror: the kernel's rule, written once in GDScript, over the same arrays.
func _reference_decisions(arrays: Dictionary) -> PackedInt32Array:
	var positions: PackedFloat32Array = arrays["positions"]
	var alive: PackedInt32Array = arrays["alive"]
	var sides: PackedInt32Array = arrays["sides"]
	var targets: PackedInt32Array = arrays["targets"]
	var reach: PackedFloat32Array = arrays["reach"]
	var due: PackedInt32Array = arrays["due"]
	var struck: PackedInt32Array = arrays["struck"]
	var bodies: PackedInt32Array = arrays["bodies"]
	var bands: PackedFloat32Array = arrays["bands"]
	var boxes: PackedFloat32Array = arrays["boxes"]
	var box_counts: PackedInt32Array = arrays["box_counts"]
	var box_offsets: PackedInt32Array = arrays["box_offsets"]
	var retention_sq: float = arrays["retention_sq"]
	var count := alive.size()
	var out := PackedInt32Array()
	out.resize(count)
	for slot in count:
		if alive[slot] == 0:
			out[slot] = NativeSoldierBatch.DECISION_NONE
			continue
		var decision := NativeSoldierBatch.DECISION_NONE
		var remember := targets[slot]
		var x := positions[slot * 2]
		var y := positions[slot * 2 + 1]
		if remember >= 0 and remember < count and alive[remember] != 0 and sides[remember] != sides[slot]:
			var dx := positions[remember * 2] - x
			var dy := positions[remember * 2 + 1] - y
			var d2 := dx * dx + dy * dy
			if d2 <= retention_sq:
				decision = NativeSoldierBatch.DECISION_KEEP if d2 <= reach[slot] * reach[slot] \
					else NativeSoldierBatch.DECISION_HOLD
		if decision == NativeSoldierBatch.DECISION_NONE and due[slot] != 0:
			var body := bodies[slot]
			if body < 0 or struck[slot] != 0:
				decision = NativeSoldierBatch.DECISION_SEARCH
			elif body < box_counts.size() and body < box_offsets.size():
				var band := bands[body]
				var first := box_offsets[body]
				var here := box_counts[body]
				var in_band := false
				for b in here:
					var at := (first + b) * 4
					var bdx := maxf(maxf(boxes[at] - x, 0.0), x - boxes[at + 2])
					var bdy := maxf(maxf(boxes[at + 1] - y, 0.0), y - boxes[at + 3])
					if bdx * bdx + bdy * bdy <= band * band:
						in_band = true
						break
				decision = NativeSoldierBatch.DECISION_SEARCH if in_band else NativeSoldierBatch.DECISION_DEFER
		out[slot] = decision
	return out
