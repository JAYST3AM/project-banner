extends Control
## Standalone visual acceptance harness for M02 Slice B1.
## Synthetic display data only: it does not launch a battle or issue simulation orders.
const FIELD := Vector2(260.0, 130.0)

var _world: Node2D
var _command: BattleCommandBar
var _overview: BattleTacticalOverview
var _formations: Array[Dictionary] = []
var _full_map := true


func _ready() -> void:
	## The preview is the visual acceptance harness, so the evidence run must be able to choose the zoom
	## mode without a keypress - a screenshot cannot press M.
	_full_map = not OS.get_cmdline_user_args().has("--medium-map")
	_world = Node2D.new()
	add_child(_world)
	var ground := Polygon2D.new()
	ground.polygon = PackedVector2Array([
		Vector2.ZERO, Vector2(FIELD.x, 0.0), FIELD, Vector2(0.0, FIELD.y)])
	ground.color = Color("384738")
	_world.add_child(ground)
	var overlay := BattleDeploymentOverlay.new()
	_world.add_child(overlay)
	overlay.configure(FIELD, 20.0, 8.0)
	_overview = BattleTacticalOverview.new()
	_world.add_child(_overview)
	_formations = [
		{"id": 1, "side": 0, "anchor": Vector2(40, 42),
		 "forward": Vector2.RIGHT, "half_depth": 8.0, "half_span": 13.0,
		 "name": "Spearmen", "alive": 32, "started": 40, "type_key": "spear"},
		{"id": 2, "side": 0, "anchor": Vector2(40, 89),
		 "forward": Vector2.RIGHT, "half_depth": 5.0, "half_span": 9.0,
		 "name": "Archers", "alive": 18, "started": 20, "type_key": "archer"},
		{"id": 3, "side": 1, "anchor": Vector2(220, 43),
		 "forward": Vector2.LEFT, "half_depth": 8.0, "half_span": 12.0,
		 "name": "Raiders", "alive": 25, "started": 30, "type_key": "sword"},
		{"id": 4, "side": 1, "anchor": Vector2(220, 92),
		 "forward": Vector2.LEFT, "half_depth": 6.0, "half_span": 9.0,
		 "name": "Bowmen", "alive": 14, "started": 20, "type_key": "bow"},
		# A destroyed body sits in the snapshot on purpose: the overview must not draw it, so a
		# screenshot showing nothing where this one stands is the evidence of that behaviour.
		{"id": 5, "side": 1, "anchor": Vector2(220, 112),
		 "forward": Vector2.LEFT, "half_depth": 6.0, "half_span": 9.0,
		 "name": "Destroyed", "alive": 0, "started": 20, "type_key": "bow"},
	]
	_overview.set_formations(_formations, [1], 4, _full_map)
	_command = BattleCommandBar.new()
	add_child(_command)
	_command.set_battle_status(false, 50, 39, 1, true, false)
	var title := Label.new()
	title.text = "M02 / B1 — COMPONENT PREVIEW — %s ZOOM (M: toggle)" % (
		"FULL-MAP" if _full_map else "MEDIUM-MAP")
	title.add_theme_color_override("font_color", Color("e9e6dc"))
	title.add_theme_font_size_override("font_size", 16)
	title.position = Vector2(24, 12)
	add_child(title)
	resized.connect(_layout)
	_layout()
	# A direct run of this scene never executes main.gd, so the global --screenshot probe is inert here;
	# take our own. Awaited, because this repo treats an un-awaited coroutine call as an error.
	var shot := _arg_value("--shot=")
	if not shot.is_empty():
		await _take_screenshot(shot, int(_arg_value("--shot-delay=", "2000")))


func _layout() -> void:
	if _world == null or _command == null:
		return
	var available := Vector2(maxf(100.0, size.x - 80.0),
		maxf(100.0, size.y - 175.0))
	var factor := minf(available.x / FIELD.x, available.y / FIELD.y)
	_world.scale = Vector2.ONE * factor
	_world.position = Vector2((size.x - FIELD.x * factor) * 0.5,
		45.0 + maxf(0.0, (available.y - FIELD.y * factor) * 0.5))
	_command.position = Vector2(20.0, maxf(0.0, size.y - 115.0))
	_command.size = Vector2(maxf(300.0, size.x - 40.0), 95.0)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("141b17"), true)


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_M:
		_full_map = not _full_map
		_overview.set_formations(_formations, [1], 4, _full_map)


func _arg_value(prefix: String, fallback: String = "") -> String:
	## Dev-run flags of the form "--name=value", read the way every other dev scene here reads them.
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(prefix):
			return arg.substr(prefix.length())
	return fallback


func _take_screenshot(path: String, delay_ms: int) -> void:
	## This harness takes its OWN screenshot. The global --screenshot probe is wired by main.gd, and a
	## direct dev-scene run never executes main.gd, so the flag is silently inert here - the same reason
	## gpu_crowd and iso_spike write their own PNGs. Verified the hard way: eight runs produced eight
	## clean logs and zero images before this existed.
	await get_tree().create_timer(maxf(0.4, float(delay_ms) / 1000.0)).timeout
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var err := image.save_png(path)
	if err == OK:
		print("preview screenshot: %s (%dx%d)" % [path, image.get_width(), image.get_height()])
	else:
		printerr("preview screenshot FAILED for %s (error %d)" % [path, err])
	if OS.get_cmdline_user_args().has("--shot-quit"):
		get_tree().quit()
