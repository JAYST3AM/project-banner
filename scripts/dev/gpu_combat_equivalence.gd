extends Node
## Real-GPU combat equivalence gate; requires windowed Vulkan.
## Usage: godotc --path <tree> res://scenes/dev/gpu_combat_equivalence.tscn
## Exit 1 for shader failure, first mismatch or non-completing battle.
func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("GPU combat equivalence requires a real windowed GPU")
		get_tree().quit(1)
		return
	var gpu := BattleGpuOrderedTargetProbe.new()
	if not gpu.open(4):
		push_error("GPU combat equivalence initialization FAILED: %s" % gpu.last_error)
		gpu.close()
		get_tree().quit(1)
		return
	var total_ticks := 0
	var total_targets := 0
	for seed_value in BattleCombatEquivalenceGate.SEEDS:
		var verdict := BattleCombatEquivalenceGate.run_seed(seed_value, gpu)
		if not bool(verdict.get("ok", false)):
			push_error("GPU COMBAT EQUIVALENCE FAIL: seed=%d tick=%d first_field=%s CPU=%s GPU=%s" % [
				seed_value, int(verdict.get("tick", -1)),
				str(verdict.get("field", "unknown")), str(verdict.get("cpu", "")),
				str(verdict.get("gpu", ""))])
			gpu.close()
			get_tree().quit(1)
			return
		total_ticks += int(verdict["ticks"])
		total_targets += int(verdict["target_checks"])
		print("GPU COMBAT EQUIVALENCE seed=%d PASS ticks=%d winner=%s casualties=%d checked_ordered_targets=%d" % [
			seed_value, int(verdict["ticks"]), str(verdict["winner"]),
			int(verdict["casualties"]), int(verdict["target_checks"])])
	gpu.close()
	print("GPU COMBAT EQUIVALENCE PASS: %d seeds, %d ticks, %d GPU ordered-target decisions; all other combat stages CPU-shadow only" % [
		BattleCombatEquivalenceGate.SEEDS.size(), total_ticks, total_targets])
	if not _run_retention():
		get_tree().quit(1)
		return
	if not _run_acquisition():
		get_tree().quit(1)
		return
	get_tree().quit(0)


## Slice 2: a separate real-GPU gate over adversarial cached-opponent
## states and the same seeded, independently simulated CPU outcomes.
func _run_retention() -> bool:
	var probe := BattleGpuRetentionProbe.new()
	if not probe.open(8):
		push_error("GPU COMBAT RETENTION FAIL: initialize: %s" % probe.last_error)
		probe.close()
		return false
	var fixture := BattleCombatRetentionGate.fixture()
	var reference := BattleCombatRetentionGate.cpu_all(fixture)
	var observed := probe.evaluate(fixture)
	var check := BattleCombatRetentionGate.compare(reference, observed, 0, fixture.units)
	if observed.is_empty() or not bool(check.get("ok", false)):
		push_error("GPU COMBAT RETENTION FAIL: fixture tick=0 first_field=%s CPU=%s GPU=%s; error=%s" % [
			str(check.get("field", "readback")), str(check.get("cpu", "")),
			str(check.get("gpu", "")), probe.last_error])
		probe.close()
		return false
	var checked := fixture.units.size()
	var retained := 0
	for seed_value in BattleCombatEquivalenceGate.SEEDS:
		var verdict := BattleCombatRetentionGate.run_seed(seed_value, probe)
		if not bool(verdict.get("ok", false)):
			push_error("GPU COMBAT RETENTION FAIL: seed=%d tick=%d first_field=%s CPU=%s GPU=%s" % [
				seed_value, int(verdict.get("tick", -1)),
				str(verdict.get("field", "unknown")), str(verdict.get("cpu", "")),
				str(verdict.get("gpu", ""))])
			probe.close()
			return false
		checked += int(verdict["gpu_decisions"])
		retained += int(verdict["valid_retained"])
		print("GPU COMBAT RETENTION seed=%d PASS ticks=%d winner=%s casualties=%d decisions=%d retained=%d" % [
			seed_value, int(verdict["ticks"]), str(verdict["winner"]),
			int(verdict["casualties"]), int(verdict["gpu_decisions"]),
			int(verdict["valid_retained"])])
	probe.close()
	if checked <= fixture.units.size() or retained <= 0:
		push_error("GPU COMBAT RETENTION FAIL: no live retained-opponent decisions exercised")
		return false
	print("GPU COMBAT RETENTION PASS: %d seeds, %d GPU decisions, %d valid retained; automatic search and all damage CPU-only" % [
		BattleCombatEquivalenceGate.SEEDS.size(), checked, retained])
	return true


## Slice 3: real Vulkan nearest-target + switching threshold decisions.
## Fixture decisions are checked in full (including other soldiers), then
## four seeded independent CPU fights are traced for every tick.
func _run_acquisition() -> bool:
	var probe := BattleGpuAcquisitionProbe.new()
	if not probe.open(6):
		push_error("GPU COMBAT ACQUISITION FAIL: initialization: %s" % probe.last_error)
		probe.close()
		return false
	var fixture_count := 0
	var reasons: Dictionary = {}
	for name in BattleCombatAcquisitionGate.CASES:
		var fixture := BattleCombatAcquisitionGate.fixture(name)
		var expected := BattleCombatAcquisitionGate.cpu_all(fixture)
		var actual := probe.evaluate(fixture)
		if actual.is_empty():
			push_error("GPU COMBAT ACQUISITION FAIL: fixture=%s first_field=gpu.readback: %s" % [
				name, probe.last_error])
			probe.close()
			return false
		var different := BattleCombatAcquisitionGate.compare(expected, actual, 0, fixture.units)
		if not bool(different.get("ok", false)):
			push_error("GPU COMBAT ACQUISITION FAIL: fixture=%s tick=0 first_field=%s CPU=%s GPU=%s" % [
				name, str(different.get("field", "unknown")),
				str(different.get("cpu", "")), str(different.get("gpu", ""))])
			probe.close()
			return false
		var known := BattleCombatAcquisitionGate.expected_for(name)
		for component in 4:
			if actual[component] != known[component]:
				push_error("GPU COMBAT ACQUISITION FAIL: fixture=%s tick=0 expected_case_component=%d CPU=%d GPU=%d" % [
					name, component, known[component], actual[component]])
				probe.close()
				return false
		reasons[int(actual[1])] = true
		fixture_count += 1
	var decisions := fixture_count * 6
	var acquisitions := 0
	var switches := 0
	for seed_value in BattleCombatEquivalenceGate.SEEDS:
		var verdict := BattleCombatAcquisitionGate.run_seed(seed_value, probe)
		if not bool(verdict.get("ok", false)):
			push_error("GPU COMBAT ACQUISITION FAIL: seed=%d tick=%d first_field=%s CPU=%s GPU=%s" % [
				seed_value, int(verdict.get("tick", -1)),
				str(verdict.get("field", "unknown")), str(verdict.get("cpu", "")),
				str(verdict.get("gpu", ""))])
			probe.close()
			return false
		decisions += int(verdict["gpu_decisions"])
		acquisitions += int(verdict["acquisitions"])
		switches += int(verdict["switches"])
		print("GPU COMBAT ACQUISITION seed=%d PASS ticks=%d winner=%s casualties=%d decisions=%d acquires=%d switches=%d" % [
			seed_value, int(verdict["ticks"]), str(verdict["winner"]),
			int(verdict["casualties"]), int(verdict["gpu_decisions"]),
			int(verdict["acquisitions"]), int(verdict["switches"])])
	probe.close()
	if reasons.size() != 8 or decisions <= fixture_count * 6 or \
			acquisitions <= 0 or switches <= 0:
		push_error("GPU COMBAT ACQUISITION FAIL: inadequate reason or live-decision coverage; reasons=%s acquired=%d switched=%d" % [
			str(reasons.keys()), acquisitions, switches])
		return false
	print("GPU COMBAT ACQUISITION PASS: 4 seeds, %d adversarial fixtures, 8/8 reasons, %d GPU decisions, %d live acquisitions, %d live switches; CPU combat authoritative" % [
		fixture_count, decisions, acquisitions, switches])
	return true
