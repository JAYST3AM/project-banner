extends Node2D
## Windowed battlefield-level GPU/CPU terrain integration acceptance fixture.
## Uses production ShowcaseBattle, BattleSimulator, BattleView and the actual
## E2 shader, not mocked terrain or an unrendered headless-only test.
## Run: godotc --path <tree> res://scenes/dev/gpu_campaign_terrain_smoke.tscn
## Exits non-zero if any source, GPU, collision or screenshot assertion fails.
const SEED := 2026
var _backend: BattleGpuTerrainCollider = null
var _output := "user://e3-terrain-windowed.png"


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_output = arg.trim_prefix("--out=")
	call_deferred("_run")


func _fail(reason: String) -> void:
	push_error("PB E3 WINDOWED FAIL: " + reason)
	if _backend != null:
		_backend.close()
	get_tree().quit(1)


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		_fail("a real windowed RenderingDevice is required")
		return
	var config := GameManager.config()
	var built := ShowcaseBattle.build(config, UnitCatalog.load_from(),
		FormationCatalog.load_from(), 3, SEED)
	var sim: BattleSimulator = built["simulator"]
	var terrain: BattlefieldTerrain = built["terrain"]
	var context: BattleContext = built["context"]
	if sim == null or terrain == null or not terrain.is_valid():
		_fail("production battle did not supply valid terrain")
		return
	var view := BattleView.new()
	add_child(view)
	view.bind(sim, context)
	view.show_units = true
	var camera := Camera2D.new()
	add_child(camera)
	camera.position = terrain.size * 0.5
	var bounds := get_viewport_rect().size
	var zoom := minf(bounds.x / terrain.size.x, bounds.y / terrain.size.y) * 0.80
	camera.zoom = Vector2(zoom, zoom)
	camera.make_current()
	var half := terrain.size.x * 0.5
	var zones: Array[Rect2] = [
		Rect2(Vector2.ZERO, Vector2(half, terrain.size.y)),
		Rect2(Vector2(half, 0), Vector2(half, terrain.size.y)),
	]
	var deployment := BattleGpuDeployment.plan(terrain, sim.units, zones)
	if not BattleGpuDeployment.apply(deployment, sim.units):
		_fail("deployment legality: %s" % str(deployment["reason"]))
		return
	var capture := BattleTerrainGpuBridge.capture(terrain, sim.units)
	if not bool(capture["ready"]) or not BattleTerrainGpuBridge.matches_source(capture, terrain):
		_fail("authoritative terrain snapshot unavailable")
		return
	_backend = BattleGpuTerrainCollider.new()
	if not _backend.open(capture, terrain, sim.units.size()):
		_fail("GPU activation: " + _backend.last_error)
		return
	var before := PackedVector2Array()
	var proposed := PackedVector2Array()
	var mask: PackedInt32Array = capture["mask"]
	for unit in sim.units:
		before.append(unit.position)
		proposed.append(unit.position + Vector2(0.30, 0.15))
	var gpu := _backend.resolve(before, proposed)
	if gpu.size() != sim.units.size():
		_fail("GPU readback: " + _backend.last_error)
		return
	var changed := 0
	for i in gpu.size():
		var expected := BattleTerrainGpuMask.slide(mask, before[i], proposed[i])
		if gpu[i].distance_to(expected) > 0.0001:
			_fail("CPU/GPU parity mismatch for soldier %d, delta=%.8f" % [
				i, gpu[i].distance_to(expected)])
			return
		if gpu[i] != before[i]:
			changed += 1
		sim.units[i].position = gpu[i]
	view.queue_redraw()
	await get_tree().process_frame
	await get_tree().process_frame
	var screenshot := get_viewport().get_texture().get_image()
	if screenshot == null or screenshot.is_empty() or screenshot.save_png(_output) != OK:
		_fail("windowed screenshot was not written: " + _output)
		return
	print("PB E3 WINDOWED PASS: backend=GPU terrain collision, battle=%s, units=%d, moved=%d, source=%s, cells=%dx%d, screenshot=%s" % [
		context.battle_id, gpu.size(), changed, str(capture["source_signature"]),
		terrain.cols, terrain.rows, _output])
	_backend.close()
	_backend = null
	get_tree().quit(0)


func _exit_tree() -> void:
	if _backend != null:
		_backend.close()
		_backend = null
