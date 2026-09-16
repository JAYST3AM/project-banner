extends Node
## Death-storm probe: what the kill cleanup costs, and what it used to cost.
##
## Clearing the orders that were hunting a soldier who has just died is a chain walk: the soldiers
## holding an order are chained onto the man they were ordered to kill, once a tick, so a death
## inspects only its own hunters (Step 7.10, D-111).
##
## Before that it was a scan of the whole roster per death - O(deaths x roster) - and that is what
## Step 7.9 measured: in this same setup and through the same production `_attack()` path, fifty deaths
## at twenty thousand soldiers cost 1,000,000 roster inspections and 160 ms, and a mass-casualty tick
## spent 98.3% of itself in the cleanup (D-110).
##
## [b]This probe measures the shipped build, which is the chain.[/b] The Step 7.9 figures are
## historical, and their tables live in D-110 and in the Step 7.9 sections of CURRENT_STATE.md and
## ROADMAP.md. They remain reproducible from this tree with `--cleanup=walk`, which measures the
## reference scan the index replaced - the same loop, over the same rosters, timed the same way - so
## the baseline is re-measurable without checking out an older revision. `--cleanup=both` runs the
## chain and the reference over one setup and asserts they release the same soldiers, so the reference
## cannot quietly drift away from what it replaces.
##
## Run:
##   godotc --headless --path "<project>" res://scenes/dev/death_storm_probe.tscn
## Optional:
##   --sizes=100,1000,5000,20000   rosters to measure
##   --deaths=50                   soldiers killed in each controlled case
##   --cleanup=chain|walk|both     chain is the shipped path and the default; walk is the Step 7.9
##                                 baseline; both checks the two agree over one setup

const TICK := 0.05
const SEED := 70909

var _sizes: Array[int] = [100, 1000, 5000, 20000]
var _deaths := 50
## Which cleanup the controlled cases measure: the shipped chain, the reference walk it replaced, or
## both with an agreement check. See the header.
var _cleanup := "chain"
var _report: Array[String] = []


func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--sizes="):
			_sizes = []
			for piece in argument.trim_prefix("--sizes=").split(","):
				_sizes.append(int(piece))
		elif argument.begins_with("--deaths="):
			_deaths = int(argument.trim_prefix("--deaths="))
		elif argument.begins_with("--cleanup="):
			_cleanup = argument.trim_prefix("--cleanup=")
	print("=== kill-cleanup probe: seed %d, sizes %s, storm %d deaths, cleanup %s ===" % [
		SEED, str(_sizes), _deaths, _cleanup])
	if _cleanup == "walk":
		print("=== reference walk: the Step 7.9 baseline the index replaced (D-110) ===")
	_report.append("size,mode,checksum,deaths,inspections,inspections_per_death,worst,clears,usec")
	for size in _sizes:
		for mode in ["none", "sparse", "all_to_one"]:
			var row := _run(size, mode)
			_report.append(row)
			print(row)
	if _cleanup != "walk":
		# The matched workload: deaths that happen inside a tick the game actually runs, rather than
		# killings the probe batches by hand. This is the evidence an auditor asked for, because a storm
		# that never passes through step() cannot claim a share of a tick. It measures the shipped
		# chain, so `walk` mode - the historical baseline - skips it.
		print("=== storm ticks (one step() each) ===")
		_report.append("size,deaths,inspections,usec,tick_usec,usec_share_pct,deaths_per_attacker")
		for size in _sizes:
			var tick_row := _run_storm_tick(size)
			_report.append(tick_row)
			print(tick_row)
	if _cleanup == "both":
		print("=== the reference against the shipped chain, over one setup ===")
		for size in _sizes:
			print(_agree(size))
	print("=== end of kill-cleanup probe ===")
	get_tree().quit()


## A storm the game itself fights: lines of attackers and one-hit-point enemies facing each other,
## every attacker ordered at the man in front of him, and then exactly one call to step(). The
## cleanup's cost is recorded for deaths that happened inside that tick, alongside the tick's own
## wall time - which is the only way "a share of a tick" can be claimed rather than inferred.
func _run_storm_tick(size: int) -> String:
	var config := GameManager.config()
	var simulator := BattleSimulator.new(config, SEED)
	simulator.profile_enabled = true
	var units: Array[BattleUnit] = []
	var pairs := size / 2
	var armed: Array[BattleUnit] = []
	var doomed: Array[BattleUnit] = []
	for i in pairs:
		# Facing pairs, one pace apart: an attacker and the enemy he is ordered to kill, standing
		# inside each other's reach so the tick resolves them.
		var y := 6.0 + float(i % 250) * 1.1
		var x := 6.0 + float(i / 250) * 2.0
		var attacker := _storm_unit(i * 2, BattleContext.SIDE_PLAYER, Vector2(x, y))
		# A cooldown of zero means he swings on this tick rather than after it, which is what makes
		# the deaths land inside the tick being measured.
		attacker.attack_cooldown = 0.0
		attacker.attack = 10
		var victim := _storm_unit(i * 2 + 1, BattleContext.SIDE_ENEMY, Vector2(x + 1.2, y))
		victim.hp = 1
		attacker.attack_order_target_id = victim.id
		units.append(attacker)
		units.append(victim)
		armed.append(attacker)
		doomed.append(victim)
	simulator.add_units(units)
	simulator.call("_rebuild_spatial", TICK)
	simulator.call("_refresh_focus")
	simulator.start()
	simulator.reset_profile()

	var started := Time.get_ticks_usec()
	simulator.step(TICK)
	var tick_usec := Time.get_ticks_usec() - started
	var share := 0.0
	if tick_usec > 0:
		share = 100.0 * float(simulator.kill_cleanup_usec) / float(tick_usec)
	return "%d,%d,%d,%d,%d,%.1f,%.2f" % [
		size, simulator.kill_cleanup_deaths, simulator.kill_cleanup_inspections,
		simulator.kill_cleanup_usec, tick_usec, share,
		float(simulator.kill_cleanup_deaths) / float(maxi(1, armed.size()))]


## A soldier for the storm: cheap, melee, and with a reach that spans the gap to his neighbour.
func _storm_unit(id: int, side: String, position: Vector2) -> BattleUnit:
	var unit := BattleUnit.new()
	unit.id = id
	unit.side = side
	unit.soldier_id = "s_tick_%d" % id
	unit.display_name = "Tick %d" % id
	unit.max_hp = 1000
	unit.hp = 1000
	unit.attack = 1
	unit.defence = 0
	unit.move_speed = 0.0
	unit.attack_range = 2.0
	unit.attack_cooldown = 1.0
	unit.position = position
	return unit


## One controlled death storm: a roster of the given size, the given share of it ordered to hunt the
## victim, and `_deaths` soldiers killed through the production attack path.
func _run(size: int, mode: String) -> String:
	var config := GameManager.config()
	var simulator := BattleSimulator.new(config, SEED)
	simulator.profile_enabled = true
	var units: Array[BattleUnit] = []
	# Half the roster per side, standing in a line a pace apart: a formation is irrelevant here, and
	# the probe wants a state the game could actually be in rather than a special one.
	for i in size:
		var unit := BattleUnit.new()
		unit.id = i
		unit.side = BattleContext.SIDE_PLAYER if i % 2 == 0 else BattleContext.SIDE_ENEMY
		unit.soldier_id = "s_storm_%d" % i
		unit.display_name = "Storm %d" % i
		unit.max_hp = 1000
		unit.hp = 1000
		unit.attack = 1
		unit.defence = 0
		unit.move_speed = 5.0
		unit.attack_range = 1.8
		unit.attack_cooldown = 1.0
		unit.position = Vector2(4.0 + float(i % 200) * 1.2, 4.0 + float(i / 200) * 1.2)
		units.append(unit)
	simulator.add_units(units)
	simulator.call("_rebuild_spatial", TICK)
	simulator.call("_refresh_focus")
	simulator.start()

	# The victims: the first `_deaths` soldiers of the enemy side, each one blow from death.
	var victims: Array[BattleUnit] = []
	for i in size:
		if units[i].side == BattleContext.SIDE_ENEMY:
			units[i].hp = 1
			victims.append(units[i])
			if victims.size() >= _deaths:
				break
	var killer: BattleUnit = units[0]

	# Orders, before the killing starts: who is hunting whom. `all_to_one` points every soldier in
	# the battle except the victim himself at the first victim - the worst case for the cleanup, and
	# the case a player's order spam could actually produce. An auditor caught the first version
	# ordering only one side while the comment claimed every living soldier; the workload the spec
	# asked for is the whole roster, so that is what this does.
	var ordered := 0
	if mode == "sparse":
		for i in size:
			if i % 10 == 0:
				units[i].attack_order_target_id = victims[0].id
				ordered += 1
	elif mode == "all_to_one":
		for i in size:
			if units[i] != victims[0]:
				units[i].attack_order_target_id = victims[0].id
				ordered += 1

	simulator.reset_profile()
	# In `walk` mode the reference does the clearing instead of the shipped chain, and it is the
	# reference's own counts that get reported - which is what makes the Step 7.9 baseline
	# re-measurable from this tree. The attacks still run through the production path, so the victims
	# die exactly as they would in a battle; by then their orders are already released, which is why
	# the production counters are ignored in this mode rather than mixed in.
	var walk_inspections := 0
	var walk_clears := 0
	var walk_usec := 0
	for victim in victims:
		if _cleanup == "walk":
			var walk_mark := Time.get_ticks_usec()
			walk_inspections += units.size()
			walk_clears += _reference_walk(units, victim)
			walk_usec += Time.get_ticks_usec() - walk_mark
		for swing in 500:
			if not victim.is_alive():
				break
			simulator.call("_attack", killer, victim)

	var quality := absf(hash("%d|%s|%d" % [size, mode, ordered]))
	var deaths := simulator.kill_cleanup_deaths
	var inspections := simulator.kill_cleanup_inspections
	var worst := simulator.kill_cleanup_worst_inspections
	var clears := simulator.kill_cleanup_clears
	var usec := simulator.kill_cleanup_usec
	if _cleanup == "walk":
		deaths = victims.size()
		inspections = walk_inspections
		worst = units.size()
		clears = walk_clears
		usec = walk_usec
	var per_death := 0
	if deaths > 0:
		per_death = inspections / deaths
	return "%d,%s,%d,%d,%d,%d,%d,%d,%d" % [
		size, mode, quality, deaths, inspections, per_death, worst, clears, usec]


## The reference the index replaced: a scan of the whole roster, clear every order pointed at the
## fallen soldier. Kept in the probe so the Step 7.9 baseline can be re-measured from this tree, which
## is the measurement equivalent of the suites keeping a brute-force reference beside the
## implementation that replaced it.
func _reference_walk(units: Array[BattleUnit], fallen: BattleUnit) -> int:
	var cleared := 0
	for unit in units:
		if unit.attack_order_target_id == fallen.id:
			unit.attack_order_target_id = -1
			cleared += 1
	return cleared


## One setup, measured twice: the shipped chain through the production attack path, and the reference
## walk over the same roster with the same orders. Both must release the same soldiers, or the
## reference is not describing what was replaced.
func _agree(size: int) -> String:
	var config := GameManager.config()
	var simulator := BattleSimulator.new(config, SEED)
	simulator.profile_enabled = true
	var units: Array[BattleUnit] = []
	for i in size:
		units.append(_storm_unit(i,
			BattleContext.SIDE_PLAYER if i % 2 == 0 else BattleContext.SIDE_ENEMY,
			Vector2(4.0 + float(i % 200) * 1.2, 4.0 + float(i / 200) * 1.2)))
	simulator.add_units(units)
	simulator.call("_rebuild_spatial", TICK)
	simulator.call("_refresh_focus")
	simulator.start()
	var killer: BattleUnit = units[0]
	var victim: BattleUnit = units[1]
	victim.hp = 1
	var hunters: Array[BattleUnit] = []
	for unit in units:
		if unit != victim and unit != killer:
			unit.attack_order_target_id = victim.id
			hunters.append(unit)
	simulator.reset_profile()
	for swing in 500:
		if not victim.is_alive():
			break
		simulator.call("_attack", killer, victim)
	var chain_clears := simulator.kill_cleanup_clears
	# The same orders back, then the reference does the same job on the same state.
	for hunter in hunters:
		hunter.attack_order_target_id = victim.id
	var reference_clears := _reference_walk(units, victim)
	var verdict := "AGREE" if chain_clears == reference_clears else "DISAGREE"
	return "size=%d hunters=%d chain_clears=%d reference_clears=%d -> %s" % [
		size, hunters.size(), chain_clears, reference_clears, verdict]
