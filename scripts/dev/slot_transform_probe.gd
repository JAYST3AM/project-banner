extends Node
## Is a body's slot lattice an exact rigid transform of the previous tick's? (Step 7.12, verification)
##
## The question this answers, before any code depends on it: if a body's slots are rebuilt from its
## anchor and facing alone, then for a body whose shape has not changed, every new slot should equal
##
##     anchor_new + rotate(old_slot - anchor_old, facing_new - facing_old)
##
## exactly - not approximately - because `_rebuild_slots` builds each slot as
## `anchor + right() * lateral + forward() * forward_offset` and those two basis vectors are the old
## ones rotated by the facing change. If that holds, a soldier standing in his place can ride his
## body's transform with four multiplies and two adds, instead of a slot lookup, a distance, a
## normalise and a terrain lookup; and it covers bodies that are *turning*, which a bare translation
## cannot. If it does not hold, the idea dies here rather than after a milestone.
##
## It samples real battles rather than a fixture: a showcase battle is driven for many ticks with both
## commanders thinking, and every body is checked every tick. Bodies whose shape changed (a death, a
## merge, a type change) are reported separately and not judged, because a changed shape is exactly
## where the claim is not expected to hold and where soldiers are supposed to dress.
##
## Run:
##   godotc --headless --path "<project>" res://scenes/dev/slot_transform_probe.tscn
## Optional: --per-side=10 --ticks=400 --seed=780780

const STEP := 0.05
const TOLERANCE := 0.0001
## The bound a soldier must be within to count as standing in his place, agreed with the reviewer as
## the acceptance tolerance for the transform slice: safely above float error (worst measured 1.7e-5)
## and well below the arrival epsilon the dressing path uses.
const IN_PLACE_TOLERANCE := 0.0001

var _per_side := 10
var _ticks := 400
var _seed := 780780
## Whether each soldier was standing on his place at the end of the previous tick, for counting re-dress
## events: a rider who stops being one has had to dress, which is the cost the transform is meant to
## remove.
var _was_in_place := {}


func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--per-side="):
			_per_side = int(argument.trim_prefix("--per-side="))
		elif argument.begins_with("--ticks="):
			_ticks = int(argument.trim_prefix("--ticks="))
		elif argument.begins_with("--seed="):
			_seed = int(argument.trim_prefix("--seed="))
	print("=== slot transform probe: %d a side, %d ticks, seed %d ===" % [_per_side, _ticks, _seed])

	var built := ShowcaseBattle.build(
		GameManager.config(), UnitCatalog.load_from(), FormationCatalog.load_from(),
		_per_side, _seed)
	var simulator: BattleSimulator = built["simulator"]
	var player_ai := BattleAI.create(GameManager.config(), BattleContext.SIDE_PLAYER)
	var enemy_ai := BattleAI.create(GameManager.config(), BattleContext.SIDE_ENEMY)
	simulator.start()

	var samples := 0
	var turning_samples := 0
	var worst_error := 0.0
	var worst_where := ""
	var shape_changed := 0
	var holding := 0
	var holding_worst := 0.0
	var worst_off_slot := 0.0
	var in_place_samples := 0
	var redress_events := 0

	for tick in _ticks:
		# Capture the lattice and the body's frame before the tick moves anything.
		var before: Array[Dictionary] = []
		for body in simulator.formations:
			before.append({
				"body": body,
				"anchor": body.anchor,
				"facing": body.facing,
				"count": body.unit_ids.size(),
				"files": body.file_count,
				"ranks": body.rank_count,
				"slots": body.slots.duplicate(),
			})
		player_ai.update(simulator, STEP)
		enemy_ai.update(simulator, STEP)
		simulator.step(STEP)

		for record in before:
			var body: BattleFormation = record["body"]
			var old_count := int(record["count"])
			if old_count == 0:
				continue
			# A shape change is not a failure of the claim - it is where the claim is not made.
			if body.unit_ids.size() != old_count \
					or body.file_count != int(record["files"]) \
					or body.rank_count != int(record["ranks"]) \
					or body.slots.size() != old_count:
				shape_changed += 1
				continue
			var old_anchor: Vector2 = record["anchor"]
			var delta := body.facing - float(record["facing"])
			var old_slots: Array[Vector2] = record["slots"]
			var turning := absf(delta) > 0.0000001
			for i in old_count:
				var expected: Vector2 = body.anchor + (old_slots[i] - old_anchor).rotated(delta)
				var error := (expected - body.slots[i]).length()
				samples += 1
				if turning:
					turning_samples += 1
				if error > worst_error:
					worst_error = error
					worst_where = "tick %d body %s slot %d delta %.6f" % [tick, body.id, i, delta]
				# And separately: is the man actually standing on the slot the transform names?
				var unit: BattleUnit = simulator._unit_by_id.get(body.unit_ids[i])
				if unit != null and unit.is_alive():
					var on_old_slot := (unit.position - old_slots[i]).length()
					if on_old_slot <= 0.05:
						holding += 1
						if error > holding_worst:
							holding_worst = error
					# Drift tracking, for the comparison the next slice has to make: is this soldier
					# standing exactly on his place, and did he stop being one who is? A rider who was
					# in place and is not any more has had to dress - the transform should reduce those.
					var off_slot := (unit.position - body.slots[i]).length()
					if off_slot > worst_off_slot:
						worst_off_slot = off_slot
					if off_slot <= IN_PLACE_TOLERANCE:
						in_place_samples += 1
						_was_in_place[unit.id] = true
					else:
						if _was_in_place.has(unit.id):
							redress_events += 1
							_was_in_place.erase(unit.id)

	print("")
	print("=== RESULT ===")
	print("  slot samples checked      : %d (of which on turning bodies: %d)" % [samples, turning_samples])
	print("  bodies skipped, shape moved: %d" % shape_changed)
	print("  worst lattice error       : %.9f  %s" % [worst_error, worst_where])
	print("  soldiers standing on their old slot: %d, worst error among them: %.9f" % [holding, holding_worst])
	print("  drift, for the next slice : worst distance from his own place %.9f, in-place samples %d, re-dress events %d" % [
		worst_off_slot, in_place_samples, redress_events])
	if samples > 0 and worst_error <= TOLERANCE:
		print("  VERDICT: the lattice is a rigid transform of the previous tick's, within %f" % TOLERANCE)
	else:
		print("  VERDICT: REJECTED - the lattice is not a rigid transform of the previous tick's")
	get_tree().quit()
