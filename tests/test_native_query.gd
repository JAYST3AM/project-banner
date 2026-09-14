extends TestCase
## Step 7.7: the native target-query accelerator, against the locked GDScript oracle.
##
## The milestone's rule is that native code accelerates a kernel and never changes a tactical
## answer. This suite is how that rule is checked rather than asserted: the same queries are
## put to both implementations and the sets they collect are compared, first over generated
## layouts, then over the boundary cases a spatial index gets wrong (cells, corners, the
## radius itself, the margin, deaths and movement after the snapshot), and finally over live
## battles in compare mode, where every automatic search a real fight makes is answered twice.
##
## When the library is not built, the suite says so and stops - a red suite for a missing
## accelerator would say nothing about the code. CI builds it and passes --require-native, so
## there a missing library is a failure.

const SEED := 77001
const TICK := 0.05
const PLAYER := BattleContext.SIDE_PLAYER
const ENEMY := BattleContext.SIDE_ENEMY
const GDSCRIPT := BattleSpatialGrid.Backend.GDSCRIPT
const NATIVE := BattleSpatialGrid.Backend.NATIVE
const COMPARE := BattleSpatialGrid.Backend.COMPARE
const NATIVE_FULL := BattleSpatialGrid.Backend.NATIVE_FULL
const COMPARE_FULL := BattleSpatialGrid.Backend.COMPARE_FULL


func run() -> void:
	await _tick()
	if not ClassDB.class_exists("NativeTargetQuery"):
		# One assertion either way, so a skipped suite still reports a check rather than
		# looking like a suite that never ran. CI builds the library and passes
		# --require-native, where the absence of the accelerator is a failure.
		if "--require-native" in OS.get_cmdline_user_args():
			equal(false, true, "the native accelerator is required but was not loaded")
		else:
			equal(false, false, "no accelerator is loaded, so there is nothing to compare")
			print("    SKIP the native query suite: no accelerator loaded (run `bash native/build.sh`)")
		_complete()
		return

	equal(ClassDB.class_exists("NativeTargetQuery"), true,
		"the accelerator class is registered with the engine")
	_test_generated_layouts_agree()
	_test_boundary_cases_agree()
	_test_live_state_is_seen_by_both_backends()
	_test_dead_units_are_never_collected()
	_test_ties_and_dense_cells()
	_test_a_huge_field_terminates()
	_test_a_realistic_battle_agrees_under_shape_b()
	_test_a_shape_b_battle_reproduces_the_reference_battle()
	_test_the_report_counts_what_the_backends_did()
	_test_the_live_state_hooks_are_the_only_ones()
	_complete()


## ------------------------------------------------ generated layouts, thousands of queries


func _test_generated_layouts_agree() -> void:
	var layouts := 12
	var points_per_layout := 220
	var compared := 0
	var mismatches := 0
	var last_grid: BattleSpatialGrid = null
	for layout in layouts:
		var rng := RandomNumberGenerator.new()
		rng.seed = SEED + layout * 7919
		var units := _scatter(rng, 1 + layout * 3)
		for shape in 3:
			var field := Vector2(60.0 + float(shape) * 120.0, 40.0 + float(shape) * 80.0)
			var grid := _grid(field, 4.0, units, COMPARE)
			last_grid = grid
			for i in points_per_layout:
				var point := Vector2(rng.randf_range(0.0, field.x), rng.randf_range(0.0, field.y))
				grid.collect_within(point, 8.0 + float(i % 4) * 8.0, ENEMY, _out())
				compared += 1
			mismatches += grid.native_mismatches
	if mismatches > 0 and last_grid != null:
		print("    first mismatch: %s" % JSON.stringify(last_grid.native_first_mismatch))
	equal(mismatches, 0, "both backends collected the same units on every generated query")
	greater(compared, 7000, "thousands of queries were compared, not a handful")
	equal(compared, layouts * 3 * points_per_layout, "every generated query was compared")


func _test_boundary_cases_agree() -> void:
	# Cells, corners, the radius itself, and a margin that reaches across a cell boundary:
	# the cases a spatial index gets wrong by one cell in either direction.
	var field := Vector2(64.0, 48.0)
	var cases: Array[Array] = [
		# [name, enemy offset from the query point, radius]
		["dead centre", Vector2(0.0, 0.0), 8.0],
		["exactly on the radius", Vector2(8.0, 0.0), 8.0],
		["a hair inside", Vector2(7.999, 0.0), 8.0],
		["a hair outside", Vector2(8.001, 0.0), 8.0],
		["across a cell boundary", Vector2(3.999, 0.0), 8.0],
		["on a cell corner", Vector2(4.0, 4.0), 8.0],
		["diagonal on the radius", Vector2(5.657, 5.657), 8.0],
		["far", Vector2(31.0, 31.0), 8.0],
	]
	for case in cases:
		var units: Array[BattleUnit] = []
		units.append(_unit(0, PLAYER, Vector2(20.0, 20.0)))
		units.append(_unit(1, ENEMY, Vector2(20.0, 20.0) + case[1]))
		var grid := _grid(field, 4.0, units, COMPARE)
		grid.collect_within(Vector2(20.0, 20.0), case[2], ENEMY, _out())
		equal(grid.native_mismatches, 0, "both backends agree: %s" % case[0])
	
	# The margin is part of the query: a coarse answer is allowed to include units beyond the
	# radius, and both backends must include the same ones.
	var units2: Array[BattleUnit] = []
	units2.append(_unit(0, PLAYER, Vector2(30.0, 30.0)))
	units2.append(_unit(1, ENEMY, Vector2(30.0 + 12.5, 30.0)))
	var margin_grid := _grid(Vector2(80.0, 60.0), 4.0, units2, COMPARE)
	margin_grid.query_margin = 6.0
	margin_grid.rebuild(units2)
	var collected := _out()
	margin_grid.collect_within(Vector2(30.0, 30.0), 8.0, ENEMY, collected)
	equal(margin_grid.native_mismatches, 0, "both backends agree with a query margin set")
	equal(collected.size(), 1, "and the margin reached the enemy the radius alone would miss")


## ------------------------------------------------ live state, after the snapshot


func _test_live_state_is_seen_by_both_backends() -> void:
	# The index is built from positions at rebuild time, and soldiers move afterwards. Both
	# backends must therefore answer about the *snapshot's* cells while the caller's exact
	# test reads live positions - and must agree about who is worth asking about.
	var units := _scatter_lines(60)
	var grid := _grid(Vector2(120.0, 80.0), 4.0, units, COMPARE)
	var point := Vector2(60.0, 40.0)
	grid.collect_within(point, 12.0, ENEMY, _out())
	equal(grid.native_mismatches, 0, "both backends agree before anything moves")

	# Move every unit a long way: cell membership is now deliberately stale, exactly as it
	# is during a soldier loop. The sets must still agree, because both walk the same stale
	# index with the same filter.
	for unit in units:
		unit.position += Vector2(7.5, -3.25)
	grid.collect_within(point, 12.0, ENEMY, _out())
	equal(grid.native_mismatches, 0, "both backends agree after the battle has moved underneath the index")

	# And a rebuild after the movement has to re-index both of them.
	grid.rebuild(units)
	grid.collect_within(point, 12.0, ENEMY, _out())
	equal(grid.native_mismatches, 0, "both backends agree after a rebuild on the new positions")


func _test_dead_units_are_never_collected() -> void:
	# A soldier can die after the index was built and before its own turn comes round. The
	# reference rechecks liveness while it walks; the accelerator cannot know, so the check
	# is made on this side of the boundary. This test is what proves that is enough.
	var units := _scatter_lines(40)
	var grid := _grid(Vector2(120.0, 80.0), 4.0, units, COMPARE)
	for unit in units:
		if unit.side == ENEMY and unit.id % 3 == 0:
			unit.alive = false
	var collected := _out()
	grid.collect_within(Vector2(60.0, 40.0), 40.0, ENEMY, collected)
	equal(grid.native_mismatches, 0, "both backends skip the soldiers that died after the rebuild")
	for unit in collected:
		equal(unit.alive, true, "no dead soldier is ever handed to the caller")


func _test_ties_and_dense_cells() -> void:
	# Equal distances, many units in one cell, and both sides sharing a cell: the cases where
	# an implementation that iterates in a different order can quietly answer differently.
	var units: Array[BattleUnit] = []
	var next_id := 0
	for i in 24:
		units.append(_unit(next_id, ENEMY, Vector2(40.0 + float(i % 6) * 0.25, 40.0 + float(i / 6) * 0.25)))
		next_id += 1
	for i in 24:
		units.append(_unit(next_id, PLAYER, Vector2(40.0 + float(i % 6) * 0.25, 40.0 + float(i / 6) * 0.25)))
		next_id += 1
	var grid := _grid(Vector2(80.0, 60.0), 1.0, units, COMPARE)
	for i in 40:
		grid.collect_within(Vector2(40.0, 40.0), 5.0 + float(i) * 0.5, ENEMY, _out())
	equal(grid.native_mismatches, 0, "both backends agree on dense and tied layouts")
	greater(grid.native_calls, 30, "and the accelerator really answered those queries")


func _test_a_huge_field_terminates() -> void:
	# A grid whose field is far larger than its army is what the widest rung of a search
	# looks like, and it is where a walk that trusts its box walks its own tail.
	var units := _scatter_lines(30)
	var grid := _grid(Vector2(4000.0, 3000.0), 4.0, units, COMPARE)
	grid.collect_within(Vector2(2000.0, 1500.0), 32.0, ENEMY, _out())
	equal(grid.native_mismatches, 0, "both backends agree on a field far bigger than the army")
	equal(grid.native_calls, 1, "and the query was answered once")


## ------------------------------------------------ live battles


func _test_a_realistic_battle_agrees_under_shape_b() -> void:
	var battle := _formed_battle(COMPARE_FULL)
	var simulator: BattleSimulator = battle["simulator"]
	var ticks := 120
	for i in ticks:
		if simulator.is_finished():
			break
		simulator.step(TICK)
	var report := simulator.backend_report()
	if report["native_mismatches"] > 0:
		print("    first mismatch: %s" % JSON.stringify(report["first_mismatch"]))
	equal(report["native_mismatches"], 0, "every automatic search in a live battle answered identically")
	greater(float(report["native_calls"]), 100.0, "and the battle really did put queries to the accelerator")


func _test_a_shape_b_battle_reproduces_the_reference_battle() -> void:
	# Two battles, one seed, one reference and one accelerated. If the accelerator changed a
	# single tactical answer the two would drift apart here - and not in a subtle way.
	var reference := _formed_battle(GDSCRIPT)
	var native := _formed_battle(NATIVE_FULL)
	var a: BattleSimulator = reference["simulator"]
	var b: BattleSimulator = native["simulator"]
	var ticks := 150
	for i in ticks:
		if a.is_finished() and b.is_finished():
			break
		if not a.is_finished():
			a.step(TICK)
		if not b.is_finished():
			b.step(TICK)

	equal(b.backend_report()["native_mismatches"], 0, "the accelerated battle ran without a disagreement to report")
	greater(float(b.backend_report()["native_calls"]), 100.0, "the accelerated battle used the accelerator")
	equal(a.units.size(), b.units.size(), "both battles field the same soldiers")
	for i in a.units.size():
		var ua := a.units[i]
		var ub := b.units[i]
		equal(ub.alive, ua.alive, "unit %d is alive in both battles or dead in both" % ua.id)
		equal(ub.hp, ua.hp, "unit %d has identical health in both battles" % ua.id)
		equal(ub.position, ua.position, "unit %d stands in exactly the same place in both battles" % ua.id)
		equal(ub.auto_target_id, ua.auto_target_id, "unit %d is fighting the same opponent in both battles" % ua.id)
	equal(b.is_finished(), a.is_finished(), "both battles finish at the same moment")
	equal(_fallen(b), _fallen(a), "both battles cost exactly the same casualties")


func _test_the_report_counts_what_the_backends_did() -> void:
	# The counters are what the milestone's numbers are read from, so they are asserted
	# rather than assumed: the accelerator reports and the differences stay at zero.
	var units := _scatter_lines(40)
	var grid := _grid(Vector2(120.0, 80.0), 4.0, units, NATIVE)
	for i in 50:
		grid.collect_within(Vector2(60.0, 40.0), 10.0 + float(i % 3) * 6.0, ENEMY, _out())
	var report := grid.backend_report()
	equal(report["backend"], NATIVE, "the report names the backend that answered")
	equal(report["native_calls"], 50, "the report counts the queries the accelerator answered")
	equal(report["native_mismatches"], 0, "and nothing disagreed")


## The accelerator's mirrored state is only true because the battle changes live state in
## exactly two places, both mirrored. This is deliberately a search of the source rather than a
## behavioural test: a third mutation point added upstream would otherwise be a silent wrong
## answer, and the comparison modes would only catch it in the battles they happen to run.
func _test_the_live_state_hooks_are_the_only_ones() -> void:
	var mover := FileAccess.open("res://scripts/battle/battle_simulator.gd", FileAccess.READ)
	var mover_text := mover.get_as_text()
	equal(mover_text.count(".position = ") + mover_text.count(".position += "), 2,
		"the battle moves soldiers in exactly two statements, both inside _move_toward")
	var owner := FileAccess.open("res://scripts/battle/battle_unit.gd", FileAccess.READ)
	equal(owner.get_as_text().count("alive = false"), 1,
		"a soldier dies in exactly one statement, mirrored where the killing blow lands")


## ------------------------------------------------ fixtures


## Soldiers that did not walk away, counted from the units themselves: the simulator has
## no casualty accessor, and counting is what the other battle suites do.
func _fallen(simulator: BattleSimulator) -> int:
	var dead := 0
	for unit in simulator.units:
		if not unit.alive:
			dead += 1
	return dead


func _out() -> Array[BattleUnit]:
	var out: Array[BattleUnit] = []
	return out


func _unit(id: int, side: String, position: Vector2, reach: float = 0.05) -> BattleUnit:
	var unit := BattleUnit.new()
	unit.id = id
	unit.side = side
	unit.soldier_id = "s_native_%d" % id
	unit.display_name = "Native %d" % id
	unit.max_hp = 1000
	unit.hp = 1000
	unit.attack = 1
	unit.defence = 0
	unit.move_speed = 5.0
	unit.attack_range = reach
	unit.attack_cooldown = 1.0
	unit.position = position
	return unit


func _grid(field: Vector2, cell: float, units: Array[BattleUnit], mode: int = GDSCRIPT) -> BattleSpatialGrid:
	var grid := BattleSpatialGrid.new()
	grid.configure(field, cell)
	# The backend must be chosen before the rebuild: the rebuild is what hands the
	# accelerator its snapshot of the field, so a backend switched on afterwards would be
	# asked to walk an index it was never given.
	grid.backend = mode
	grid.rebuild(units)
	return grid


## A layout with both sides mixed through the field, so a query finds friends and enemies in
## the same cells and the side filter has something to do.
func _scatter(rng: RandomNumberGenerator, per_side: int) -> Array[BattleUnit]:
	var units: Array[BattleUnit] = []
	var next_id := 0
	for i in per_side:
		units.append(_unit(next_id, PLAYER, Vector2(rng.randf_range(2.0, 180.0), rng.randf_range(2.0, 140.0))))
		next_id += 1
	for i in per_side:
		units.append(_unit(next_id, ENEMY, Vector2(rng.randf_range(2.0, 180.0), rng.randf_range(2.0, 140.0))))
		next_id += 1
	return units


## Two facing lines, deterministic, packed at the density a battle actually uses.
func _scatter_lines(per_side: int) -> Array[BattleUnit]:
	var units: Array[BattleUnit] = []
	var next_id := 0
	for side_value in [PLAYER, ENEMY]:
		var side := str(side_value)
		var left := side == PLAYER
		for i in per_side:
			var x := 40.0 - float(i % 6) * 1.1 if left else 80.0 + float(i % 6) * 1.1
			var y := 10.0 + float(i / 6) * 2.2
			units.append(_unit(next_id, side, Vector2(x, y)))
			next_id += 1
	return units


## A formed, fighting battle on the same rails the other target suites use: two armies, real
## formations, real AI, stepped by the caller.
func _formed_battle(mode: int) -> Dictionary:
	var config := GameManager.config()
	var field := Vector2(240.0, 160.0)
	var units: Array[BattleUnit] = []
	var next_id := 0
	var middle := field.x * 0.5
	var per_side := 150
	for side_value in [PLAYER, ENEMY]:
		var side := str(side_value)
		var left := side == PLAYER
		var files := maxi(1, per_side / 4)
		for i in per_side:
			var file := i % files
			var rank := i / files
			var x := (middle - 40.0 * 0.5) - float(rank) * 1.4 if left \
				else (middle + 40.0 * 0.5) + float(rank) * 1.4
			var y := field.y * 0.2 + float(file) * (field.y * 0.6 / float(files))
			var unit := _unit(next_id, side, Vector2(x, y), 1.8)
			unit.max_hp = 40
			unit.hp = 40
			unit.attack = 5
			unit.defence = 2
			next_id += 1
			units.append(unit)

	var simulator := BattleSimulator.new(config, SEED)
	simulator.field_size = field
	simulator.grid.configure(field, simulator.cell_size)
	simulator.overlap_grid.configure(field, simulator.overlap_cell_size)
	simulator.add_units(units)
	BattleSetup.assign_default_formations(simulator, config)
	simulator.target_backend = mode
	simulator.call("_rebuild_spatial", TICK)
	simulator.call("_refresh_focus")
	simulator.start()
	return {"simulator": simulator}
