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
	get_tree().quit(0)
