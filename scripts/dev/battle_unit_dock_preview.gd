extends Control
## Windowed B2a roster acceptance harness. Synthetic snapshots; no battle or campaign state.
## --shot=ABSOLUTE.png --shot-size=1280x720 --shot-delay=2500 --shot-quit
var _dock: BattleUnitDock
var _status: Label
var _selected: Array[int] = [1]
var _bodies: Array[Dictionary] = [
	{"id": 1, "side": 0, "name": "Greywatch Spears", "type_key": "spearman",
	 "alive": 32, "started": 40, "shape": "line", "order": "HOLD"},
	{"id": 2, "side": 0, "name": "Longbowmen", "type_key": "archer",
	 "alive": 5, "started": 20, "shape": "loose", "order": "FIRE"},
	{"id": 3, "side": 0, "name": "Fallen Vanguard", "type_key": "peasant_recruit",
	 "alive": 0, "started": 25, "shape": "wedge", "order": "HOLD"},
	{"id": 4, "side": 0, "name": "Unknown Class", "type_key": "missing_unit",
	 "alive": 12, "started": 12, "shape": "line", "order": "MOVE"},
	{"id": 9, "side": 1, "name": "Enemy (hidden)", "type_key": "bandit_ruffian",
	 "alive": 20, "started": 20},
]


func _ready() -> void:
	_dock = BattleUnitDock.new()
	add_child(_dock)
	_dock.body_chosen.connect(_on_body_chosen)
	_dock.update_bodies(_bodies, _selected)
	var title := Label.new()
	title.text = "M02 / B2a — FORMATION ROSTER"
	title.add_theme_color_override("font_color", Color("e9e6dc"))
	title.add_theme_font_size_override("font_size", 20)
	title.position = Vector2(24, 18)
	add_child(title)
	_status = Label.new()
	_status.add_theme_color_override("font_color", Color("b5b8a7"))
	_status.add_theme_font_size_override("font_size", 14)
	add_child(_status)
	_update_status()
	resized.connect(_layout)
	_layout()
	var shot := _arg_value("--shot=")
	if not shot.is_empty():
		await _take_screenshot(shot, int(_arg_value("--shot-delay=", "2500")),
			_arg_value("--shot-size="))


func _layout() -> void:
	if _dock == null or _status == null:
		return
	_dock.position = Vector2(24, 82)
	_dock.size = Vector2(maxf(320.0, size.x - 48.0), 126)
	_status.position = Vector2(24, 230)
	_status.size = Vector2(maxf(320.0, size.x - 48.0), 55)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("141b17"), true)


func _update_status() -> void:
	_status.text = "Selection: %s   |   Click to replace, Shift-click to toggle   |   0-strength cards disabled" % str(_selected)


func _on_body_chosen(id: int, additive: bool) -> void:
	if additive:
		if _selected.has(id):
			_selected.erase(id)
		else:
			_selected.append(id)
	else:
		_selected = [id]
	_dock.update_bodies(_bodies, _selected)
	_update_status()


func _arg_value(prefix: String, fallback: String = "") -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(prefix):
			return arg.substr(prefix.length())
	return fallback


func _take_screenshot(path: String, delay_ms: int, size_arg: String) -> void:
	## Direct dev scenes bypass main.gd and its global screenshot probe. The user's
	## GameSettings.apply() also overrides an early --resolution, so resize at shutter time.
	await get_tree().create_timer(maxf(0.4, float(delay_ms) / 1000.0)).timeout
	if not size_arg.is_empty():
		var parts := size_arg.split("x")
		if parts.size() == 2:
			get_window().size = Vector2i(int(parts[0]), int(parts[1]))
			await get_tree().process_frame
			await get_tree().process_frame
			await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var err := image.save_png(path)
	if err == OK:
		print("B2a roster screenshot: %s (%dx%d) window %s" % [
			path, image.get_width(), image.get_height(), str(get_window().size)])
	else:
		printerr("B2a roster screenshot FAILED for %s (error %d)" % [path, err])
	if OS.get_cmdline_user_args().has("--shot-quit"):
		get_tree().quit()
