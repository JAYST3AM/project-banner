extends Control
## Slice C visual evidence: what the ground painter produces, at a glance.
##
## Three things are shown deliberately, because GPT-6 asked for them rather than for a generic corner:
##   - TERRAIN VARIETY: the whole battlefield at once, so the spread of types and soils is visible together.
##   - RELIEF: a 4x zoom onto the roughest ground the field contains, where the illumination term is legible.
##   - THE BOUNDARY: the baked image stops exactly at the battlefield's edge, drawn here with a border.
##
## Dev-only harness, not part of the painter's production surface. Flags: --shot=PATH, --shot-size=WxH,
## --shot-delay=MS, --shot-quit, and --alt-seed to bake the same field under a second seed for comparison.
const FIELD := Vector2(100.0, 60.0)
const SEED := 70717
const FULL_BOX := Rect2(28.0, 84.0, 640.0, 384.0)
const ZOOM_BOX := Rect2(700.0, 84.0, 480.0, 288.0)
const ZOOM_FACTOR := 4.0
const ZOOM_SOURCE := Vector2i(110, 66)

var _terrain: BattlefieldTerrain
var _image: Image
var _texture: ImageTexture
var _zoom_region: Rect2i
var _status: Label


func _ready() -> void:
	var alt := OS.get_cmdline_user_args().has("--alt-seed")
	_terrain = BattlefieldTerrain.generate(SEED + (1 if alt else 0), FIELD, GameManager.config())
	_image = BattleGroundPainter.bake(_terrain)
	if _image != null:
		_texture = ImageTexture.create_from_image(_image)
		_zoom_region = _roughest_region()
	_add_labels(alt)
	queue_redraw()

	var shot := _arg_value("--shot=")
	if not shot.is_empty():
		await _take_screenshot(shot, int(_arg_value("--shot-delay=", "2500")),
			_arg_value("--shot-size="))


func _add_labels(alt: bool) -> void:
	var title := Label.new()
	title.text = "M02 / Slice C — GROUND PAINTER%s" % (" — SECOND SEED" if alt else "")
	title.add_theme_color_override("font_color", Color("e9e6dc"))
	title.add_theme_font_size_override("font_size", 20)
	title.position = Vector2(28.0, 20.0)
	add_child(title)

	var legend := Label.new()
	legend.text = "left: THE WHOLE BATTLEFIELD — the image ends at the boundary   ·   " \
		+ "right: 4x ON THE ROUGHEST GROUND, where the illumination term is legible"
	legend.add_theme_color_override("font_color", Color("b5b8a7"))
	legend.add_theme_font_size_override("font_size", 13)
	legend.position = Vector2(28.0, 52.0)
	add_child(legend)

	var boundary := Label.new()
	boundary.text = "battlefield boundary"
	boundary.add_theme_color_override("font_color", Color("f1d38a"))
	boundary.add_theme_font_size_override("font_size", 12)
	boundary.position = Vector2(FULL_BOX.position.x + 2.0, FULL_BOX.end.y + 6.0)
	add_child(boundary)

	_status = Label.new()
	_status.add_theme_color_override("font_color", Color("b5b8a7"))
	_status.add_theme_font_size_override("font_size", 13)
	_status.position = Vector2(28.0, 512.0)
	add_child(_status)
	_update_status(alt)


func _update_status(alt: bool) -> void:
	if _terrain == null or _image == null:
		_status.text = "the terrain or the bake failed"
		return
	var kinds := _terrain.counts_by_type()
	var soils := _terrain.counts_by_soil()
	_status.text = "seed %d%s   |   field %dx%d world units   |   grid %dx%d cells   |   image %dx%d px%s" % [
		SEED + (1 if alt else 0), " (alt)" if alt else "", int(FIELD.x), int(FIELD.y),
		_terrain.cols, _terrain.rows, _image.get_width(), _image.get_height(),
		"   |   %d terrain types, %d soils across %d cells" % [
			kinds.size(), soils.size(), _terrain.cell_count()]]


## The window of the field with the greatest height spread, so the zoom lands on real relief rather than on
## whatever happens to be in a corner.
func _roughest_region() -> Rect2i:
	var best := Rect2i(0, 0, ZOOM_SOURCE.x, ZOOM_SOURCE.y)
	var best_spread := -1.0
	for row in range(0, maxi(1, _image.get_height() - ZOOM_SOURCE.y), 8):
		for col in range(0, maxi(1, _image.get_width() - ZOOM_SOURCE.x), 8):
			var low := 1e9
			var high := -1e9
			for y in range(row, row + ZOOM_SOURCE.y, 6):
				for x in range(col, col + ZOOM_SOURCE.x, 6):
					var v := _image.get_pixel(x, y).v
					low = minf(low, v)
					high = maxf(high, v)
			if high - low > best_spread:
				best_spread = high - low
				best = Rect2i(col, row, ZOOM_SOURCE.x, ZOOM_SOURCE.y)
	return best


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("141b17"), true)
	if _texture == null:
		return
	# The whole battlefield, with its boundary drawn as a hard edge - this is where the image stops.
	draw_texture_rect(_texture, FULL_BOX, false)
	draw_rect(FULL_BOX, Color("a79a75"), false, 1.0)
	# And the roughest ground at 4x, nearest-neighbour so individual texels stay legible.
	var zoom := Rect2(ZOOM_BOX.position, Vector2(_zoom_region.size) * ZOOM_FACTOR)
	draw_texture_rect_region(_texture, zoom, Rect2(_zoom_region))
	draw_rect(zoom, Color("a79a75"), false, 1.0)


func _arg_value(prefix: String, fallback: String = "") -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(prefix):
			return arg.substr(prefix.length())
	return fallback


func _take_screenshot(path: String, delay_ms: int, size_arg: String) -> void:
	## Direct dev scenes bypass main.gd's global screenshot probe, and the owner's GameSettings.apply()
	## overrides an early --resolution, so the resize happens at shutter time.
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
		print("Slice C ground screenshot: %s (%dx%d)" % [path, image.get_width(), image.get_height()])
	else:
		printerr("Slice C ground screenshot FAILED for %s (error %d)" % [path, err])
	if OS.get_cmdline_user_args().has("--shot-quit"):
		get_tree().quit()
