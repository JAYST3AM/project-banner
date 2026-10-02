extends Control
## The company banner screen (D-167).
##
## Opens after New Game, before the campaign starts: the player founds the company by
## painting the banner it marches under, and from then on that cloth rides the player's
## marker on the campaign map. The payload carries the campaign name and seed chosen in
## the menu; [method confirm] creates the campaign with the painted banner and moves on,
## [method back] returns to the menu without creating anything.
##
## The paint surface is [constant BannerData]'s grid; every tool the owner approved in
## the paint prototype is here - pencil, fill, eraser, mirror, wind, grid, undo, clear,
## starters and the three detail levels. Detail is detail only: the cloth's size in the
## world never changes, so the previews prove what the map will wear at every level.
##
## The read-only accessors under "for the tests" exist so a suite can drive this screen
## through the same methods its buttons drive - not a parallel test path.

const BODY := Color(0.13, 0.15, 0.19)
const LIGHT := Color(0.38, 0.42, 0.48)
const DARK := Color(0.06, 0.07, 0.09)
const OUTLINE := Color(0.02, 0.02, 0.03)
const DIM := Color(0.66, 0.68, 0.72)
const GRID_W := 288.0
const GRID_H := 360.0
const UNDO_LIMIT := 120

var _campaign_name: String = "A New Banner"
var _seed_value: int = 0
var _banner: BannerData = null
var _font: Font = null
var _button_styles: Dictionary = {}
var _selected_colour: int = 10
var _tool: String = "pencil"
var _mirror: bool = false
var _wind: bool = true
var _grid_on: bool = true
var _undo: Array[PackedInt32Array] = []

var _grid: PaintGrid = null
var _views: Array[BannerView] = []
var _status: Label = null
var _swatches: Array[Button] = []


func _ready() -> void:
	var payload: Dictionary = SceneManager.consume_payload()
	_campaign_name = str(payload.get("campaign_name", _campaign_name))
	_seed_value = int(payload.get("seed_value", 0))
	var incoming: Variant = payload.get("banner", null)
	if incoming is BannerData:
		_banner = incoming as BannerData
	else:
		_banner = BannerData.create_default()
	_font = PixelStyle.pixel_font()
	_button_styles = PixelStyle.button_styles(BODY, LIGHT, DARK, UiTheme.ACCENT, OUTLINE)
	theme = PixelStyle.tooltip_theme(BODY, UiTheme.ACCENT, UiTheme.TEXT)
	_build()
	DebugLogger.info("banner editor opened: '%s', %dx%d grid, %d cells painted" % [
		_campaign_name, _banner.width, _banner.height, _banner.painted_count(),
	], "BannerEditor")


# ---------------------------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------------------------

func _build() -> void:
	var background := ColorRect.new()
	background.color = Color(0.05, 0.06, 0.08)
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(background)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 48)
	margin.add_theme_constant_override("margin_right", 48)
	margin.add_theme_constant_override("margin_top", 30)
	margin.add_theme_constant_override("margin_bottom", 30)
	add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)

	column.add_child(PixelStyle.pixel_label("FOUND YOUR COMPANY", 22, UiTheme.GOLD))
	column.add_child(PixelStyle.body_label(
		"%s - paint the banner the company marches under. Every colour is from the game's locked palette." % _campaign_name,
		15, DIM))
	column.add_child(PixelStyle.rule(LIGHT.darkened(0.3)))

	var main := HBoxContainer.new()
	main.add_theme_constant_override("separation", 30)
	column.add_child(main)
	_build_paint_column(main)
	_build_preview_column(main)

	column.add_child(PixelStyle.rule(LIGHT.darkened(0.3)))
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 10)
	column.add_child(actions)
	var begin := _text_button("Begin Campaign", Vector2(220.0, 46.0))
	begin.pressed.connect(confirm)
	actions.add_child(begin)
	var back_button := _text_button("Back", Vector2(140.0, 46.0))
	back_button.pressed.connect(back)
	actions.add_child(back_button)


func _build_paint_column(parent: HBoxContainer) -> void:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	column.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	parent.add_child(column)

	column.add_child(PixelStyle.pixel_label("PIXEL PAINT", 11, UiTheme.GOLD))
	_grid = PaintGrid.new()
	_grid.editor = self
	_grid.grid_size = Vector2(GRID_W, GRID_H)
	_grid.custom_minimum_size = Vector2(GRID_W, GRID_H)
	column.add_child(_grid)

	_swatches.clear()
	var palette_row := GridContainer.new()
	palette_row.columns = 10
	palette_row.add_theme_constant_override("h_separation", 4)
	palette_row.add_theme_constant_override("v_separation", 4)
	column.add_child(palette_row)
	var palette := BannerData.palette()
	for i in palette.size():
		var swatch := Button.new()
		swatch.custom_minimum_size = Vector2(24.0, 24.0)
		swatch.tooltip_text = "#" + palette[i].to_html(false)
		swatch.focus_mode = Control.FOCUS_NONE
		swatch.pressed.connect(_select_colour.bind(i))
		palette_row.add_child(swatch)
		_swatches.append(swatch)
	_refresh_swatches()

	var tool_row := HBoxContainer.new()
	tool_row.add_theme_constant_override("separation", 5)
	column.add_child(tool_row)
	var group := ButtonGroup.new()
	var pencil := _tool_button("pencil", group)
	pencil.button_pressed = true
	pencil.toggled.connect(_on_tool_toggled.bind("pencil"))
	tool_row.add_child(pencil)
	var fill := _tool_button("fill", group)
	fill.toggled.connect(_on_tool_toggled.bind("fill"))
	tool_row.add_child(fill)
	var eraser := _tool_button("erase", group)
	eraser.toggled.connect(_on_tool_toggled.bind("erase"))
	tool_row.add_child(eraser)
	var mirror := _tool_button("mirror", null)
	mirror.toggled.connect(_on_mirror_toggled)
	tool_row.add_child(mirror)
	var wind := _tool_button("wind", null)
	wind.button_pressed = true
	wind.toggled.connect(_on_wind_toggled)
	tool_row.add_child(wind)
	var grid_toggle := _tool_button("grid", null)
	grid_toggle.button_pressed = true
	grid_toggle.toggled.connect(_on_grid_toggled)
	tool_row.add_child(grid_toggle)
	var undo_button := _tool_button("undo", null, false)
	undo_button.pressed.connect(undo)
	tool_row.add_child(undo_button)
	var clear_button := _tool_button("clear", null, false)
	clear_button.pressed.connect(clear)
	tool_row.add_child(clear_button)

	var starter_row := HBoxContainer.new()
	starter_row.add_theme_constant_override("separation", 5)
	column.add_child(starter_row)
	starter_row.add_child(PixelStyle.body_label("starters", 13, DIM))
	var starters: Array = [
		["split", "pale"], ["chevron", "chev"], ["cross", "cross"],
		["quarters", "quart"], ["blank", "blank"],
	]
	for entry in starters:
		var pair: Array = entry
		var starter_button := _tool_button(str(pair[0]), null, false)
		starter_button.pressed.connect(apply_starter.bind(str(pair[1])))
		starter_row.add_child(starter_button)

	var detail_row := HBoxContainer.new()
	detail_row.add_theme_constant_override("separation", 5)
	column.add_child(detail_row)
	detail_row.add_child(PixelStyle.body_label("detail", 13, DIM))
	for size in BannerData.detail_sizes():
		var detail_button := _tool_button("%dx%d" % [size.x, size.y], null, false)
		detail_button.tooltip_text = "A finer grid on the same cloth - the banner's size in the game never changes."
		detail_button.pressed.connect(set_detail.bind(size.x, size.y))
		detail_row.add_child(detail_button)

	_status = PixelStyle.body_label("", 13, DIM)
	column.add_child(_status)
	_refresh_status()


func _build_preview_column(parent: HBoxContainer) -> void:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(column)

	column.add_child(PixelStyle.pixel_label("PREVIEWS", 11, UiTheme.GOLD))
	column.add_child(PixelStyle.body_label("In the company panel - 5x", 13, DIM))
	var panel_view := BannerView.new()
	panel_view.banner = _banner
	panel_view.view_scale = 5.0
	panel_view.custom_minimum_size = Vector2(320.0, 372.0)
	_views.append(panel_view)
	column.add_child(panel_view)

	column.add_child(PixelStyle.body_label("On the campaign map - true scale (0.75 px per unit)", 13, DIM))
	var map_view := BannerView.new()
	map_view.banner = _banner
	map_view.view_scale = 0.75
	map_view.map_mode = true
	map_view.custom_minimum_size = Vector2(320.0, 150.0)
	_views.append(map_view)
	column.add_child(map_view)

	column.add_child(PixelStyle.body_label(
		"At map scale the cloth is about 24 x 30 pixels - fine detail reads as colour blocks; that is the honest size.",
		12, DIM))


func _text_button(text: String, min_size: Vector2) -> Button:
	return PixelStyle.text_button(text, _button_styles, 13, min_size, UiTheme.TEXT, Color(0.45, 0.47, 0.51))


func _tool_button(text: String, group: ButtonGroup, toggle: bool = true) -> Button:
	var button := Button.new()
	button.text = text
	PixelStyle.dress_button(button, _button_styles, _font, 11, UiTheme.TEXT, Color(0.45, 0.47, 0.51))
	button.custom_minimum_size = Vector2(0.0, 30.0)
	button.toggle_mode = toggle
	button.focus_mode = Control.FOCUS_NONE
	if group != null:
		button.button_group = group
	return button


# ---------------------------------------------------------------------------------------------
# Tools and painting
# ---------------------------------------------------------------------------------------------

func _select_colour(index: int) -> void:
	_selected_colour = index
	_refresh_swatches()
	_refresh_status()


func _refresh_swatches() -> void:
	var palette := BannerData.palette()
	for i in _swatches.size():
		var swatch := _swatches[i]
		var style := StyleBoxFlat.new()
		style.bg_color = palette[clampi(i, 0, palette.size() - 1)]
		style.set_border_width_all(2)
		style.border_color = UiTheme.ACCENT if i == _selected_colour else OUTLINE
		style.set_corner_radius_all(0)
		swatch.add_theme_stylebox_override("normal", style)
		swatch.add_theme_stylebox_override("hover", style)
		swatch.add_theme_stylebox_override("pressed", style)
		swatch.add_theme_stylebox_override("focus", style)


func _on_tool_toggled(pressed: bool, tool_name: String) -> void:
	if pressed:
		_tool = tool_name


func _on_mirror_toggled(pressed: bool) -> void:
	_mirror = pressed


func _on_wind_toggled(pressed: bool) -> void:
	_wind = pressed
	for view in _views:
		view.wind = pressed
		view.queue_redraw()


func _on_grid_toggled(pressed: bool) -> void:
	_grid_on = pressed
	if _grid != null:
		_grid.queue_redraw()


## One paint action from the grid: a click, or one cell of a drag.
##
## [param is_drag] is what keeps the fill tool honest - it acts on the press and never
## again for the rest of the stroke, so dragging across the cloth cannot flood it
## repeatedly.
func paint_at(x: int, y: int, erase: bool, is_drag: bool) -> void:
	if _banner == null or x < 0 or y < 0:
		return
	var value := BannerData.EMPTY if erase else _selected_colour
	if _tool == "fill":
		if is_drag:
			return
		_flood(x, y, value)
		_after_change()
		return
	if _tool == "erase":
		value = BannerData.EMPTY
	_banner.set_cell(x, y, value)
	if _mirror:
		_banner.set_cell(_banner.width - 1 - x, y, value)
	_after_change()


func _flood(start_x: int, start_y: int, value: int) -> void:
	if _banner == null or not _banner.allowed(start_x, start_y):
		return
	var target := _banner.cell(start_x, start_y)
	if target == value:
		return
	var stack: Array[Vector2i] = [Vector2i(start_x, start_y)]
	var seen := {}
	while not stack.is_empty():
		var cell: Vector2i = stack.pop_back()
		var key := cell.y * _banner.width + cell.x
		if seen.has(key):
			continue
		seen[key] = true
		if not _banner.allowed(cell.x, cell.y) or _banner.cell(cell.x, cell.y) != target:
			continue
		_banner.cells[cell.y * _banner.width + cell.x] = value
		if _mirror:
			var mx := _banner.width - 1 - cell.x
			if _banner.allowed(mx, cell.y):
				stack.append(Vector2i(mx, cell.y))
		stack.append(Vector2i(cell.x, cell.y - 1))
		stack.append(Vector2i(cell.x, cell.y + 1))
		stack.append(Vector2i(cell.x - 1, cell.y))
		stack.append(Vector2i(cell.x + 1, cell.y))


func _push_undo() -> void:
	if _banner == null:
		return
	_undo.append(_banner.cells.duplicate())
	if _undo.size() > UNDO_LIMIT:
		_undo.pop_front()


func begin_stroke() -> void:
	_push_undo()


func undo() -> void:
	if _banner == null or _undo.is_empty():
		return
	_banner.cells = _undo.pop_back()
	_after_change()


func clear() -> void:
	if _banner == null:
		return
	_push_undo()
	_banner.cells.fill(BannerData.EMPTY)
	_after_change()


func apply_starter(kind: String) -> void:
	if _banner == null:
		return
	_push_undo()
	_banner.fill_starter(kind)
	_after_change()


## Switch the paint detail. The design resets: a 32x40 painting cannot be a 8x10
## painting, and the owner's call in the prototype was that changing the grid starts a
## fresh design rather than inventing a resample nobody asked for.
func set_detail(w: int, h: int) -> void:
	if _banner != null and _banner.width == w and _banner.height == h:
		return
	_banner = BannerData.create_default(w, h)
	_undo.clear()
	for view in _views:
		view.banner = _banner
	DebugLogger.info("banner detail %dx%d (design reset)" % [w, h], "BannerEditor")
	_after_change()


func _after_change() -> void:
	_refresh_status()
	if _grid != null:
		_grid.queue_redraw()
	for view in _views:
		view.queue_redraw()


func _refresh_status() -> void:
	if _status == null or _banner == null:
		return
	var palette := BannerData.palette()
	var colour := "none"
	if _selected_colour >= 0 and _selected_colour < palette.size():
		colour = "#" + palette[_selected_colour].to_html(false)
	_status.text = "%dx%d - painted %d of %d - colour %s" % [
		_banner.width, _banner.height, _banner.painted_count(), _banner.allowed_count(), colour,
	]


# ---------------------------------------------------------------------------------------------
# The flow: confirm starts the campaign, back returns to the menu.
# ---------------------------------------------------------------------------------------------

## Begin Campaign. This is the button's own handler, callable by name so the suites drive
## the real path rather than a copy of it.
func confirm() -> void:
	DebugLogger.info("banner confirmed: %dx%d, %d cells painted - starting '%s'" % [
		_banner.width, _banner.height, _banner.painted_count(), _campaign_name,
	], "BannerEditor")
	GameManager.new_campaign(_campaign_name, _seed_value, _banner)
	SceneManager.change_scene("world_map")


func back() -> void:
	DebugLogger.info("banner editor: back to the menu", "BannerEditor")
	SceneManager.change_scene("main_menu")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		back()
		get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------------------------
# Read-only access for the tests. They read and drive state through the screen's own
# methods, not node paths, so the layout can change around them.
# ---------------------------------------------------------------------------------------------

func current_banner() -> BannerData:
	return _banner


func painted_count() -> int:
	return _banner.painted_count() if _banner != null else 0


func grid_visible() -> bool:
	return _grid_on


## Paint one cell directly - the same write a pencil stroke makes, minus the stroke
## bookkeeping. For suites.
func paint_cell(x: int, y: int, index: int) -> void:
	if _banner == null:
		return
	_banner.set_cell(x, y, index)
	_after_change()


# ---------------------------------------------------------------------------------------------
# The paint surface itself.
# ---------------------------------------------------------------------------------------------

class PaintGrid extends Control:
	var editor: Node = null
	var grid_size := Vector2(288.0, 360.0)
	var hover := Vector2i(-1, -1)
	var _drawing := false

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

	func _cell_size() -> float:
		var banner: BannerData = editor.call("current_banner")
		if banner == null or banner.width <= 0:
			return 1.0
		return grid_size.x / float(banner.width)

	func _cell_at(point: Vector2) -> Vector2i:
		var banner: BannerData = editor.call("current_banner")
		if banner == null:
			return Vector2i(-1, -1)
		var cell := _cell_size()
		var x := int(floor(point.x / cell))
		var y := int(floor(point.y / cell))
		if x < 0 or y < 0 or x >= banner.width or y >= banner.height:
			return Vector2i(-1, -1)
		return Vector2i(x, y)

	func _gui_input(event: InputEvent) -> void:
		if editor == null:
			return
		var button := event as InputEventMouseButton
		if button != null:
			var cell := _cell_at(button.position)
			if cell.x < 0:
				return
			if button.pressed:
				_drawing = true
				editor.call("begin_stroke")
				editor.call("paint_at", cell.x, cell.y, button.button_index == MOUSE_BUTTON_RIGHT, false)
			else:
				_drawing = false
			return
		var motion := event as InputEventMouseMotion
		if motion != null:
			var cell := _cell_at(motion.position)
			if cell != hover:
				hover = cell
				queue_redraw()
			if not _drawing:
				return
			var right := (motion.button_mask & MOUSE_BUTTON_MASK_RIGHT) != 0
			var left := (motion.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0
			if not right and not left:
				return
			editor.call("paint_at", cell.x, cell.y, right, true)

	func _draw() -> void:
		var banner: BannerData = editor.call("current_banner")
		if banner == null:
			return
		var cell := _cell_size()
		var palette := BannerData.palette()
		for y in banner.height:
			for x in banner.width:
				var rect := Rect2(Vector2(float(x), float(y)) * cell, Vector2(cell, cell))
				if not banner.allowed(x, y):
					draw_rect(rect, Color(0.055, 0.07, 0.09))
					continue
				var value := banner.cell(x, y)
				if value == BannerData.EMPTY:
					var light_square := (x + y) % 2 == 0
					draw_rect(rect, Color(0.06, 0.07, 0.09) if light_square else Color(0.10, 0.12, 0.15))
				else:
					draw_rect(rect, palette[clampi(value, 0, palette.size() - 1)])
		if editor.call("grid_visible"):
			var line := Color(1.0, 1.0, 1.0, 0.055)
			for x in banner.width + 1:
				draw_line(Vector2(float(x) * cell, 0.0),
					Vector2(float(x) * cell, float(banner.height) * cell), line, 1.0)
			for y in banner.height + 1:
				draw_line(Vector2(0.0, float(y) * cell),
					Vector2(float(banner.width) * cell, float(y) * cell), line, 1.0)
		if hover.x >= 0 and banner.allowed(hover.x, hover.y):
			draw_rect(Rect2(Vector2(float(hover.x), float(hover.y)) * cell, Vector2(cell, cell)),
				Color(1.0, 1.0, 1.0, 0.10))
		draw_rect(Rect2(Vector2.ZERO, Vector2(float(banner.width), float(banner.height)) * cell),
			Color(1.0, 1.0, 1.0, 0.12), false, 1.0)


# ---------------------------------------------------------------------------------------------
# A live preview of the banner: the panel view at 5x, or a strip of campaign map at true scale.
# ---------------------------------------------------------------------------------------------

class BannerView extends Control:
	var banner: BannerData = null
	var wind := true
	var view_scale := 5.0
	var map_mode := false
	var _cache := {}

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

	func _process(_delta: float) -> void:
		if wind:
			queue_redraw()

	func _draw() -> void:
		if map_mode:
			draw_rect(Rect2(Vector2.ZERO, size), Color(0.14, 0.19, 0.15))
			var road_y := size.y * 0.72
			draw_rect(Rect2(0.0, road_y - 6.0, size.x, 12.0), Color(0.30, 0.26, 0.18, 0.20))
			draw_rect(Rect2(0.0, road_y, size.x, 4.0), Color(0.56, 0.48, 0.33))
		if banner == null:
			return
		var anchor_y := (size.y * 0.72 + 2.0) if map_mode else (size.y - 10.0)
		var t := Time.get_ticks_msec() / 1000.0
		BannerArt.draw_marker(self, _cache, banner, Vector2(size.x * 0.5, anchor_y), t,
			wind and BannerArt.wind_enabled(), view_scale)
