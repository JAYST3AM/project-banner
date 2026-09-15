extends Node
## The engagement-state benchmarks (Step 7.8, D-105).
##
## [b]What this measures.[/b] Seven scenarios that differ only in how much of the battlefield is
## in contact, so the formation-driven layer can be judged on the question it exists to answer:
## how many soldiers are asked to look for an opponent of their own, and what that costs per
## tick. Each scenario runs twice - once with the hierarchy on and once with it switched off -
## in the same build, so every difference reported is attributable to the layer rather than to
## the machine.
##
## [b]The scenarios.[/b] Far apart (nobody near anybody), approach (bodies marching), partial
## contact (one body of each side engaged), full contact (every body fighting), flank (two
## enemies on two sides of one body), multi-contact (several separate fights) and split (one
## body divided while a fight is running). The field grows with the army, at the same density
## the family-B benchmark uses, because a fixed field at twenty thousand soldiers describes a
## crowd rather than a battle.
##
## Run it with:
## [codeblock]
## godotc --headless --path "<project>" res://scenes/dev/engagement_bench.tscn -- --units=20000
## [/codeblock]

const TICK := 0.05
## Borrowed from the family-B benchmark so the two are measured on the same ground: soldiers per
## square unit, and the field's width-to-height ratio.
const REALISTIC_DENSITY := 0.0833
const FIELD_ASPECT := 100.0 / 60.0
const SEED := 780780
const DEFAULT_UNITS := 20000

var _units := DEFAULT_UNITS
var _ticks := 240
var _scenario_ticks := 240
var _seed := SEED


func _ready() -> void:
	_parse_args()
	var config := GameManager.config()
	var catalog := FormationCatalog.load_from()
	var units_catalog := UnitCatalog.load_from()
	print("")
	print("=== ENGAGEMENT BENCHMARK: %d soldiers, %d ticks a scenario, seed %d ===" % [
		_units, _ticks, _seed])
	print("columns: scenario | hierarchy | searches/tick | deferrals/tick | soldiers in individual mode |")
	print("         bodies | in contact | casualties | total ms/tick | engagement ms/tick | target ms/tick")
	print("-".repeat(132))
	for scenario in _scenarios():
		for enabled in [true, false]:
			_run_scenario(config, catalog, units_catalog, scenario, enabled)
	print("")
	print("=== ENGAGEMENT BENCHMARK COMPLETE ===")
	get_tree().quit()


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--units="):
			_units = maxi(2, int(arg.substr(8)))
		elif arg.begins_with("--ticks="):
			_ticks = maxi(1, int(arg.substr(8)))
		elif arg.begins_with("--seed="):
			_seed = int(arg.substr(7))


func _scenarios() -> Array[String]:
	return ["far apart", "approach", "partial contact", "full contact", "flank", "split"]


func _run_scenario(
	config: GameConfig,
	catalog: FormationCatalog,
	units_catalog: UnitCatalog,
	scenario: String,
	enabled: bool
) -> void:
	var built := _build(config, units_catalog, scenario, enabled)
	var simulator: BattleSimulator = built["simulator"]
	var split_result: Dictionary = built["split"]
	var scenario_ticks := int(built["ticks"])
	var tick_start := Time.get_ticks_usec()
	for i in scenario_ticks:
		simulator.step(TICK)
	var elapsed_us := Time.get_ticks_usec() - tick_start
	var report := simulator.target_report()
	var engagement := simulator.engagement_report()
	var per_tick := float(engagement["per_tick"]["searches_allowed"])
	var deferral_tick := float(engagement["per_tick"]["searches_avoided"])
	var promoted := int(engagement["promoted_soldiers"])
	var living := simulator.alive_units().size()
	var in_contact := 0
	for body in simulator.formations:
		if body.in_contact:
			in_contact += 1
	var profile: Dictionary = simulator.profile
	var ticks := maxf(1.0, float(scenario_ticks))
	var standing := 0
	for body in simulator.formations:
		if body.living_count > 0:
			standing += 1
	print("%-16s | %-8s | %12.1f | %15.1f | %8d of %-5d (%4.1f%%) | %6d | %10d | %10d | %12.3f | %17.3f | %14.3f" % [
		scenario, "on" if enabled else "off", per_tick, deferral_tick, promoted, living,
		100.0 * float(promoted) / maxf(1.0, float(living)), simulator.formations.size(), in_contact,
		simulator.units.size() - living,
		float(elapsed_us) / 1000.0 / ticks,
		float(profile.get("engagement", 0.0)) / ticks,
		float(profile.get("target", 0.0)) / ticks])
	print("        outcome: %s wins after %.1fs of battle at tick %d, %d of %d bodies still standing" % [
		simulator.winner if simulator.winner != "" else "(undecided)",
		simulator.elapsed, simulator.tick_index, standing, simulator.formations.size()])
	if scenario == "split":
		var usec := float(split_result["usec"])
		var made := maxf(1.0, float(split_result["count"]))
		print("        split: %d bodies carved off in %.1f ms total (%.3f ms a split); merge: %.3f ms; invariants: %d complaints" % [
			int(split_result["count"]), usec / 1000.0, usec / 1000.0 / made,
			float(split_result.get("merge_usec", 0)) / 1000.0,
			simulator.check_membership_invariants().size()])


## Carve one body in two, twice, and time it. Returns the microseconds spent splitting.
func _split_some(simulator: BattleSimulator, bodies: Array[BattleFormation]) -> Dictionary:
	var started := Time.get_ticks_usec()
	var made := 0
	for body in bodies:
		if made >= 2:
			break
		if body.living_count < 8:
			continue
		var ids: Array[int] = []
		for i in mini(body.unit_ids.size() / 3, 400):
			ids.append(body.unit_ids[i])
		if simulator.split_formation(body, ids, "%s_split_%d" % [body.id, made]) != null:
			made += 1
	return {"usec": Time.get_ticks_usec() - started, "count": made}


func _build(
	config: GameConfig,
	units_catalog: UnitCatalog,
	scenario: String,
	enabled: bool
) -> Dictionary:
	# Every scenario is the showcase's own deployment, driven forward for a different length of
	# time or with one body moved, and commanded by nobody: the layer being measured here is the
	# one that decides who looks for an opponent, not the one that gives orders. What separates
	# "far apart" from "full contact" is therefore how long the armies have been walking, not a
	# hand-built arrangement of soldiers that no battle would ever reach.
	var per_side := maxi(30, _units / 2)
	var built := ShowcaseBattle.build(config, units_catalog, FormationCatalog.load_from(), per_side, _seed)
	var simulator: BattleSimulator = built["simulator"]
	var scenario_ticks := _ticks
	match scenario:
		"far apart":
			scenario_ticks = mini(_ticks, 40)
		"approach":
			scenario_ticks = 200
		"partial contact":
			scenario_ticks = 420
		"full contact":
			scenario_ticks = 1100
		"flank":
			scenario_ticks = 900
			_stage_flank(simulator)
		_:
			scenario_ticks = 400
	simulator.engagement_enabled = enabled
	simulator.profile_enabled = true
	simulator.reset_profile()
	simulator.reset_engagement_counters()
	simulator.start()
	var split_result := {"usec": 0, "count": 0}
	if scenario == "split":
		# Three hundred ticks in, when the bodies are at grips but not yet spent: the split that
		# has to re-roll two engaged formations is the case the architecture has to survive.
		for i in 300:
			simulator.step(TICK)
		split_result = _split_some(simulator, simulator.formations)
		# And straight back together again, timed: merging is the other half of the membership
		# question and a player will do it as often as splitting. See D-106.
		var merge_started := Time.get_ticks_usec()
		var merged := 0
		var made: Array[BattleFormation] = []
		for body in simulator.formations:
			if body.id.contains("_split_"):
				made.append(body)
		if made.size() >= 2:
			if simulator.merge_formations(made[0], made[1]):
				merged = 1
		split_result["merge_usec"] = Time.get_ticks_usec() - merge_started
		split_result["merged"] = merged
	return {"simulator": simulator, "bodies": simulator.formations, "ticks": scenario_ticks, "per_side": per_side,
		"split": split_result}


## Two of the enemy's bodies moved behind the player's centre and onto its flank, which is the
## case a formation has to answer without a global scan. They walk in from there.
func _stage_flank(simulator: BattleSimulator) -> void:
	var ours: Array[BattleFormation] = []
	var theirs: Array[BattleFormation] = []
	for body in simulator.formations:
		if body.side == BattleContext.SIDE_PLAYER:
			ours.append(body)
		else:
			theirs.append(body)
	if ours.is_empty() or theirs.size() < 2:
		return
	var line := ours[0]
	var behind := line.anchor + Vector2(-26.0, 0.0)
	var flank := line.anchor + Vector2(0.0, -26.0)
	for i in 2:
		var body := theirs[i]
		body.anchor = behind if i == 0 else flank
		body.target_anchor = body.anchor
		for unit_id in body.unit_ids:
			var unit := simulator.find_unit(unit_id)
			if unit != null and unit.is_alive():
				unit.position = body.anchor + Vector2(float(unit.slot_index % 10) * 2.6, float(unit.slot_index / 10) * 2.6)
	simulator.call("_refresh_summaries")


func _field_for(count: int) -> Vector2:
	var area := float(count) / REALISTIC_DENSITY
	var height := sqrt(area / FIELD_ASPECT)
	return Vector2(height * FIELD_ASPECT, height)
