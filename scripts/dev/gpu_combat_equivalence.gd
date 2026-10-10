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
