extends Node
## What one per-soldier operation costs, measured rather than assumed (Step 7.11).
##
## The per-soldier loop is the largest measured phase of a tick - 203.1 ms of a 399.0 ms tick at
## twenty thousand soldiers in the fixed-area benchmark - and automatic target selection accounts for
## 72.1 ms of it. The remaining ~131 ms is not a mystery any more, it is arithmetic: the benchmark's own
## counters show that at twenty thousand soldiers **every soldier, every tick** resolves a target (so
## each one pays a facing normalise and a range check), takes the formed path, computes his formation
## slot, looks up the terrain under him, and calls the native accelerator to mirror his new position.
##
## Counts cannot be spent. This probe prices each of those operations in isolation, on live state, in
## the same build - so the 131 ms can be attributed rather than described. The method is the project's
## usual one: the same operation repeated many times over a state the game could actually be in, timed
## as a block, divided by the calls. The loops are written out longhand rather than through a Callable,
## because a lambdas's call overhead is the same order as the operations being measured.
##
## [b]What it does not do.[/b] It does not change the game, and the counts it uses for the per-tick
## totals are the benchmark's, not its own - it prints the price of one call, and the multiplication is
## left to the report where the counts and the prices can be read together.
##
## Run:
##   godotc --headless --path "<project>" res://scenes/dev/unit_price_probe.tscn
## Optional: --units=20000 --iterations=200000

const TICK := 0.05
const SEED := 71111

var _units := 20000
var _iterations := 200000


func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--units="):
			_units = int(argument.trim_prefix("--units="))
		elif argument.begins_with("--iterations="):
			_iterations = int(argument.trim_prefix("--iterations="))
	print("=== per-soldier price probe: %d soldiers, %d iterations each ===" % [_units, _iterations])

	var simulator := _setup()
	if simulator == null:
		print("no grid or terrain: the probe needs the battle's real state to price anything")
		get_tree().quit()
		return
	var roster: Array[BattleUnit] = simulator.units
	if roster.is_empty():
		print("no soldiers")
		get_tree().quit()
		return
	var warm: BattleUnit = roster[0]

	# The facing normalise and the range check: two square roots, one per soldier per tick, for every
	# soldier that has a target - which the benchmark measured as every soldier.
	var facing_mark := Time.get_ticks_usec()
	for i in _iterations:
		var _facing := (warm.position - roster[i % roster.size()].position).normalized()
	var facing_us := Time.get_ticks_usec() - facing_mark
	var range_mark := Time.get_ticks_usec()
	for i in _iterations:
		var _in_reach := warm.position.distance_to(roster[i % roster.size()].position) <= warm.attack_range
	var range_us := Time.get_ticks_usec() - range_mark

	# The formation slot: a lookup and a transform per formed soldier per tick.
	var slot_mark := Time.get_ticks_usec()
	for i in _iterations:
		var _place := roster[i % roster.size()].formation_slot()
	var slot_us := Time.get_ticks_usec() - slot_mark

	# The terrain under his feet, read by `_effective_speed` for every soldier that moves.
	var terrain_mark := Time.get_ticks_usec()
	var terrain := simulator.terrain
	for i in _iterations:
		var _multiplier := terrain.move_multiplier_at(roster[i % roster.size()].position)
	var terrain_us := Time.get_ticks_usec() - terrain_mark

	# The one that cannot be seen from GDScript at all: the call across the language boundary that
	# mirrors a moving soldier into the accelerator. It is idempotent - it stamps the unit's own
	# position - so calling it repeatedly on the same state measures the call and not the change.
	var grid = simulator.grid
	var native_mark := Time.get_ticks_usec()
	for i in _iterations:
		grid.native_moved(roster[i % roster.size()])
	var native_us := Time.get_ticks_usec() - native_mark

	# The call overhead itself: an empty function, so everything measured above can be read as
	# "the operation plus the act of calling it", and the subtraction is honest.
	var overhead_mark := Time.get_ticks_usec()
	for i in _iterations:
		_touch(roster[i % roster.size()])
	var overhead_us := Time.get_ticks_usec() - overhead_mark

	# `_can_press_forward` runs for every formed soldier before his slot is even read, so it is a
	# per-soldier call whatever it answers. It is private, and GDScript does not enforce that - so it
	# is priced twice, through the dynamic `call()` that a reader might expect and through a direct
	# `simulator._can_press_forward(...)`, because the control loop above is a direct call and the two
	# mechanisms are not the same cost. An auditor caught exactly that mismatch in the first version.
	var press_us := 0
	var press_dynamic_us := 0
	var bodies := simulator.formations
	if not bodies.is_empty():
		var dynamic_mark := Time.get_ticks_usec()
		for i in _iterations:
			simulator.call("_can_press_forward", roster[i % roster.size()], bodies[0])
		press_dynamic_us = Time.get_ticks_usec() - dynamic_mark
		var press_mark := Time.get_ticks_usec()
		for i in _iterations:
			simulator._can_press_forward(roster[i % roster.size()], bodies[0])
		press_us = Time.get_ticks_usec() - press_mark

	print("")
	print("=== WHAT ONE CALL COSTS (microseconds, then what it costs a tick at the counted rates) ===")
	print("  grid backend in this run: %s - stepped once, so this is the backend the battle itself runs (NATIVE_FULL = %d)" % [
		_grid_backend_name(simulator), BattleSpatialGrid.Backend.NATIVE_FULL])
	print("%7s | %28s | %14s | %14s | %14s" % [
		"iterations", "operation", "us per call", "calls per tick", "us per tick at 20k"])
	print("-".repeat(78))
	_row("(call overhead: empty function)", overhead_us, _iterations, _units)
	_row("facing normalise (2 sqrt)", facing_us, _iterations, _units)
	_row("range check (distance_to)", range_us, _iterations, _units)
	_row("formation_slot()", slot_us, _iterations, _units)
	_row("terrain multiplier", terrain_us, _iterations, _units)
	_row("native_moved()", native_us, _iterations, _units)
	if press_us > 0:
		_row("_can_press_forward() direct", press_us, _iterations, _units)
		_row("_can_press_forward() via call()", press_dynamic_us, _iterations, _units)
	print("-".repeat(78))
	var total_us := _per_tick(facing_us, _iterations) + _per_tick(range_us, _iterations) \
		+ _per_tick(slot_us, _iterations) + _per_tick(terrain_us, _iterations) \
		+ _per_tick(native_us, _iterations) + _per_tick(press_us, _iterations)
	var net_us := total_us - _per_tick(overhead_us, _iterations) * 6.0
	print("  the measured operations together: %.3f ms of a tick" % (total_us / 1000.0))
	print("  of which the act of calling them is about %.3f ms (six calls per soldier)" % (
		_per_tick(overhead_us, _iterations) * 6.0 / 1000.0))
	print("  so the arithmetic itself is about %.3f ms of a tick, before the loop that runs it" % (
		net_us / 1000.0))
	get_tree().quit()


## A real battle at the requested size, built the way the storm probe builds one: two halves facing
## each other, placed, given the real grid and the real terrain, and started. Nothing runs a tick -
## the probe only needs the state to price operations against.
func _setup() -> BattleSimulator:
	var config := GameManager.config()
	var simulator := BattleSimulator.new(config, SEED)
	var units: Array[BattleUnit] = []
	for i in _units:
		var unit := BattleUnit.new()
		unit.id = i
		unit.side = BattleContext.SIDE_PLAYER if i % 2 == 0 else BattleContext.SIDE_ENEMY
		unit.soldier_id = "s_price_%d" % i
		unit.display_name = "Price %d" % i
		unit.max_hp = 100
		unit.hp = 100
		unit.attack = 1
		unit.defence = 0
		unit.move_speed = 5.0
		unit.attack_range = 1.8
		unit.attack_cooldown = 1.0
		unit.position = Vector2(4.0 + float(i % 200) * 1.2, 4.0 + float(i / 200) * 1.2)
		units.append(unit)
	simulator.add_units(units)
	# Real ground under their feet: the storm probe runs without terrain and `_effective_speed`
	# handles that, but the terrain lookup is one of the things being priced, so it has to exist.
	simulator.set_terrain(BattlefieldTerrain.generate(SEED, simulator.field_size, config))
	# Formed, for real. `formation_slot()` early-returns an unformed soldier's own position, so
	# pricing it over a loose roster would measure nothing at all. One body per side is enough:
	# what is being priced is the slot lookup every formed soldier pays, not the shape of a line.
	var catalog := FormationCatalog.load_from()
	for side in [BattleContext.SIDE_PLAYER, BattleContext.SIDE_ENEMY]:
		var mine: Array[int] = []
		for unit in units:
			if unit.side == side:
				mine.append(unit.id)
		if mine.is_empty():
			continue
		var body := BattleFormation.create("%s_price_body" % side, side, Vector2.ZERO, 0.0, "line",
			catalog, config)
		simulator.add_formation(body)
		simulator.assign_formation(body, mine)
	simulator.call("_rebuild_spatial", TICK)
	simulator.call("_refresh_focus")
	simulator.start()
	# One tick, so the backend is the one the battle actually runs. `start()` chooses the backend from
	# the army size and `_rebuild_spatial()` applies it - one assignment a tick - so a probe that only
	# priced calls would read the pre-tick grid and quietly price the GDScript reference while claiming
	# to price the accelerator. That is exactly what the first version did, and an auditor caught it.
	simulator.step(TICK)
	return simulator


## The control for the price table: an empty function taking a unit, called exactly as the measured
## ones are, so the difference between a row and this row is the operation and not the calling of it.
func _touch(_unit: BattleUnit) -> void:
	pass


## Which search backend the priced grid is actually running, named rather than assumed. The native
## measurement below is only the native case if this says NATIVE_FULL - an auditor asked for exactly
## that to be established rather than hoped for.
func _grid_backend_name(simulator: BattleSimulator) -> String:
	if simulator.grid == null:
		return "no grid"
	if simulator.grid.backend == BattleSpatialGrid.Backend.NATIVE_FULL:
		return "NATIVE_FULL"
	if simulator.grid.backend == BattleSpatialGrid.Backend.GDSCRIPT:
		return "GDSCRIPT"
	return "unknown (%d)" % simulator.grid.backend


func _per_tick(spent_us: int, iterations: int) -> float:
	if iterations <= 0:
		return 0.0
	return float(spent_us) / float(iterations) * float(_units)


func _row(label: String, spent_us: int, iterations: int, calls_per_tick: int) -> void:
	var per_call := 0.0
	if iterations > 0:
		per_call = float(spent_us) / float(iterations)
	print("%7d | %25s | %11.4f us | %11d | %11.3f ms" % [
		iterations, label, per_call, calls_per_tick, _per_tick(spent_us, iterations) / 1000.0])
