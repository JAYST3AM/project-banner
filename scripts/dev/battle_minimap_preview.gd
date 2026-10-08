extends Control
## Windowed B2b acceptance harness for the tactical minimap. SYNTHETIC FIXTURES ONLY: no battle, no
## campaign, no GPU battlefield - B2b is explicitly not wired to the live field yet, so nothing here
## depends on one.
##
## Flags: --shot=ABSOLUTE.png --shot-size=WxH --shot-delay=MS --shot-quit, plus --no-terrain to capture the
## state where NO terrain imagery was ever supplied, which is a first-class state rather than a broken one.
##
## The terrain image is generated here in code - coarse blocks of two greens. The minimap draws whatever
## image it is handed and does not care who painted it; that decoupling is the point of this slice, and the
## synthetic image is what proves the minimap never needed BattleGroundPainter.
const FIELD := Vector2(600.0, 320.0)

var _minimap: BattleMinimap
var _status: Label
var _formations: Array[Dictionary] = [
	{"id": 1, "side": 0, "anchor": Vector2(140, 90), "forward": Vector2.RIGHT, "alive": 32,
	 "half_depth": 14.0, "half_span": 30.0},
	{"id": 2, "side": 0, "anchor": Vector2(120, 230), "forward": Vector2(0.3, -0.9), "alive": 18,
	 "half_depth": 10.0, "half_span": 20.0},
	{"id": 3, "side": 0, "anchor": Vector2(200, 160), "forward": Vector2.RIGHT, "alive": 0,
	 "half_depth": 8.0, "half_span": 14.0},
	{"id": 4, "side": 1, "anchor": Vector2(470, 120), "forward": Vector2.LEFT, "alive": 25,
	 "half_depth": 13.0, "half_span": 26.0},
	{"id": 5, "side": 1, "anchor": Vector2(500, 240), "forward": Vector2(-0.2, -0.95), "alive": 12,
	 "half_depth": 9.0, "half_span": 18.0},
]


func _ready() -> void:
	var with_terrain := not OS.get_cmdline_user_args().has("--no-terrain")
	_minimap = BattleMinimap.new()
	_minimap.position = Vector2(28.0, 92.0)
	_minimap.size = Vector2(470.0, 310.0)
	add_child(_minimap)
	_minimap.set_terrain_texture(_terrain_image() if with_terrain else null, FIELD)
	_minimap.set_battle_state(_formations, [1], Vector2(300.0, 160.0), Vector2(260.0, 140.0))

	var title := Label.new()
	title.text = "M02 / B2b — TACTICAL MINIMAP — %s" % (
		"TERRAIN IMAGE SUPPLIED" if with_terrain else "NO TERRAIN IMAGE")
	title.add_theme_color_override("font_color", Color("e9e6dc"))
	title.add_theme_font_size_override("font_size", 20)
	title.position = Vector2(28.0, 20.0)
	add_child(title)

	var legend := Label.new()
	legend.text = "friendly teal left / hostile red right   ·   gold outline = selected (formation 1)   ·   " \
		+ "thin rectangle = the camera's footprint   ·   the destroyed formation is not drawn"
	legend.add_theme_color_override("font_color", Color("b5b8a7"))
	legend.add_theme_font_size_override("font_size", 13)
	legend.position = Vector2(28.0, 52.0)
	add_child(legend)

	_status = Label.new()
	_status.add_theme_color_override("font_color", Color("b5b8a7"))
	_status.add_theme_font_size_override("font_size", 13)
	_status.position = Vector2(28.0, 418.0)
	add_child(_status)
	_update_status(with_terrain)

	var shot := _arg_value("--shot=")
	if not shot.is_empty():
		await _take_screenshot(shot, int(_arg_value("--shot-delay=", "2500")),
			_arg_value("--shot-size="))


func _update_status(with_terrain: bool) -> void:
	_status.text = "terrain imagery: %s   |   field %.0fx%.0f   |   camera centre (300,160) span (260,140)" % [
		"supplied" if with_terrain else "none - flat field, still fully functional", FIELD.x, FIELD.y]


func _terrain_image() -> ImageTexture:
	## Synthetic ground: coarse blocks of two greens, 48x26, generated here. Nothing in the game paints this;
	## the caller would, and the minimap only ever receives the finished image.
	var image := Image.create_empty(48, 26, false, Image.FORMAT_RGBA8)
	for y in 26:
		for x in 48:
			var light := ((x / 6) + (y / 5)) % 2 == 0
			image.set_pixel(x, y, Color("46543a") if light else Color("3d4a33"))
	return ImageTexture.create_from_image(image)


func _arg_value(prefix: String, fallback: String = "") -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(prefix):
			return arg.substr(prefix.length())
	return fallback


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("141b17"), true)


func _take_screenshot(path: String, delay_ms: int, size_arg: String) -> void:
	## Direct dev scenes bypass main.gd and its global screenshot probe, and the owner's
	## GameSettings.apply() overrides an early --resolution, so the resize happens at shutter time.
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
		print("B2b minimap screenshot: %s (%dx%d) window %s" % [
			path, image.get_width(), image.get_height(), str(get_window().size)])
	else:
		printerr("B2b minimap screenshot FAILED for %s (error %d)" % [path, err])
	if OS.get_cmdline_user_args().has("--shot-quit"):
		get_tree().quit()
