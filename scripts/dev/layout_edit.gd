class_name LayoutEditLayer
extends Control
## Dev-only composition layer for the New Campaign screen's Banner Editor.
##
## Activated by [code]--layout-edit[/code] and nothing else. The editor's
## production containers are dismantled and the five major regions - the tools
## cluster, the edit canvas, the banner hero, the founder slot and the map -
## are reparented into this manual layer, where their rects can genuinely be
## dragged and resized (no container overwrites them). The arrangement is
## copied as JSON (relative to the Banner Editor content rect), saved to a
## dev draft file, and later baked back into containers by hand.
##
## While editing, the regions still render for real - the banner waves, the
## grid shows the paint, the previews draw. Only input goes to this layer.
##
## Keys: arrows nudge 1px, Shift+arrows 5px, Tab cycles the selection, Alt
## during a drag ignores snapping, F12 drops a screenshot into user://.
## Buttons: COPY LAYOUT (clipboard + log), SAVE DRAFT, RESET, plus a close
## that simply hides the panel and restores clicks to nothing (the game
## screen itself is inert while this mode is on, by design).

const DRAFT_PATH := "user://banner_layout_draft.json"
const HANDLE := 7.0
const GRID := 2.0
const SNAP_PX := 6.0
const MIN_SCALE_STEP := 0.1

const REGION_NAMES: Array[String] = [
	"editor_controls", "editor_canvas", "pole_frame", "founder_frame", "map_frame",
]
const REGION_LABELS := {
	"editor_controls": "ToolsCluster",
	"editor_canvas": "EditCanvas",
	"pole_frame": "HeroBanner",
	"founder_frame": "Founder",
	"map_frame": "MapPreview",
}

var _regions: Array = []          # [{name, label, node, prod: Rect2, min: Vector2}]
var _selected := -1
var _drag_mode := ""              # "", "move", "resize"
var _drag_handle := -1            # 0..7 corners/edges
var _drag_origin := Vector2.ZERO  # mouse at drag start
var _drag_rect := Rect2()
var _guides: Array = []           # [[vertical: bool, coord: float]]
var _panel: PanelContainer = null
var _info: Label = null
var _hint: Label = null


# -------------------------------------------------------------------------------------------
# Activation
# -------------------------------------------------------------------------------------------

## Dismantle the workspace's containers and take over the five regions.
func start(workspace: Control) -> void:
	name = "layout_edit_layer"
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	workspace.add_child(self)
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var origin := workspace.global_position
	# The production workspace shrinks to its content; emptied of containers it would
	# collapse to nothing. Pin it to the size it had, then let it fill the frame.
	var ws_size := workspace.size
	workspace.size_flags_vertical = Control.SIZE_EXPAND_FILL
	workspace.custom_minimum_size = ws_size
	var shells: Array[Node] = []
	for region_name in REGION_NAMES:
		var node := workspace.find_child(region_name, true, false) as Control
		if node == null:
			DebugLogger.info("layout edit: region '%s' not found" % region_name, "LayoutEdit")
			continue
		var local := Rect2(node.global_position - origin, node.size)
		node.reparent(self)
		node.position = local.position
		node.size = local.size
		_go_inert(node)
		_regions.append({
			"name": region_name,
			"label": REGION_LABELS.get(region_name, region_name),
			"node": node,
			"prod": local,
			"min": node.get_combined_minimum_size(),
		})
	# Leftover container shells (the hero column and its support row) are empty now.
	for shell_name in ["editor_hero", "editor_support"]:
		var shell := workspace.find_child(shell_name, true, false)
		if shell != null and shell.get_child_count() == 0:
			shell.queue_free()
	# And the workspace's own straight-line columns are gone with the extraction.
	for child in workspace.get_children():
		if child != self and child is Control and not _is_region_node(child):
			shells.append(child)
	for shell in shells:
		shell.queue_free()

	_build_panel()
	await get_tree().process_frame
	await get_tree().process_frame
	_panel.position = Vector2(180.0, maxf(10.0, size.y - _panel.size.y - 10.0))
	_load_draft()
	_refresh_panel()
	DebugLogger.info("layout edit active: %d regions" % _regions.size(), "LayoutEdit")
	if DevFlags.layout_export():
		_copy_layout()


func _is_region_node(node: Node) -> bool:
	for region in _regions:
		if region["node"] == node:
			return true
	return false


# -------------------------------------------------------------------------------------------
# Panel
# -------------------------------------------------------------------------------------------

func _build_panel() -> void:
	_panel = PanelContainer.new()
	# Bottom-left of the editor: the empty well under the tools cluster, so the
	# panel never sits on the canvas or the hero. Placed once the layout settles.
	_panel.position = Vector2(10.0, maxf(10.0, size.y - 150.0))
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.04, 0.08, 0.94)
	style.border_color = Color(1.0, 0.25, 0.9, 0.9)
	style.set_border_width_all(2)
	style.set_content_margin_all(10.0)
	_panel.add_theme_stylebox_override("panel", style)
	add_child(_panel)

	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 6)
	_panel.add_child(rows)

	var title := Label.new()
	title.text = "LAYOUT EDIT (dev only - --layout-edit)"
	title.add_theme_color_override("font_color", Color(1.0, 0.45, 0.95))
	rows.add_child(title)

	_info = Label.new()
	_info.text = "Selected: -"
	rows.add_child(_info)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 6)
	rows.add_child(buttons)
	_add_button(buttons, "COPY LAYOUT", _copy_layout)
	_add_button(buttons, "SAVE DRAFT", _save_draft)
	_add_button(buttons, "RESET", _reset)
	_add_button(buttons, "SCREENSHOT", _screenshot)

	_hint = Label.new()
	_hint.text = "click: select | drag: move | edge/corner: resize (corners keep ratio)\nalt: no snap | arrows: 1px, shift+arrows: 5px | tab: cycle | f12: screenshot"
	_hint.add_theme_color_override("font_color", Color(0.75, 0.75, 0.8))
	rows.add_child(_hint)


func _add_button(row: HBoxContainer, text: String, handler: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(handler)
	row.add_child(button)


func _refresh_panel() -> void:
	if _info == null:
		return
	if _selected < 0 or _selected >= _regions.size():
		_info.text = "Selected: -"
		return
	var region: Dictionary = _regions[_selected]
	var rect: Rect2 = region["node"].get_rect()
	_info.text = "Selected: %s\nX: %d   Y: %d\nW: %d   H: %d" % [
		region["label"], int(rect.position.x), int(rect.position.y),
		int(rect.size.x), int(rect.size.y),
	]


# -------------------------------------------------------------------------------------------
# Input
# -------------------------------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	var motion := event as InputEventMouseMotion
	if motion != null and _drag_mode != "":
		_drag_to(motion.position)
		return
	var button := event as InputEventMouseButton
	if button == null or button.button_index != MOUSE_BUTTON_LEFT:
		return
	if not button.pressed:
		_end_drag()
		return
	grab_focus()
	var handle := _handle_at(button.position)
	if handle >= 0:
		_selected = _handle_region
		_drag_handle = handle
	elif _hit_region(button.position) >= 0:
		_selected = _hit_region(button.position)
		_drag_handle = -1
	else:
		_selected = -1
		_refresh_panel()
		queue_redraw()
		return
	_drag_mode = "resize" if _drag_handle >= 0 else "move"
	_drag_origin = button.position
	_drag_rect = (_regions[_selected]["node"] as Control).get_rect()
	_refresh_panel()
	queue_redraw()


var _handle_region := -1


func _handle_at(point: Vector2) -> int:
	for i in _regions.size():
		var rect: Rect2 = (_regions[i]["node"] as Control).get_rect()
		if not rect.grow(HANDLE).has_point(point):
			continue
		var handle := 0
		if point.x <= rect.position.x + HANDLE:
			handle |= 1
		elif point.x >= rect.end.x - HANDLE:
			handle |= 2
		if point.y <= rect.position.y + HANDLE:
			handle |= 4
		elif point.y >= rect.end.y - HANDLE:
			handle |= 8
		_handle_region = i
		return handle if handle != 0 else -1
	return -1


func _hit_region(point: Vector2) -> int:
	for i in range(_regions.size() - 1, -1, -1):
		var rect: Rect2 = (_regions[i]["node"] as Control).get_rect()
		if rect.has_point(point):
			return i
	return -1


func _end_drag() -> void:
	_drag_mode = ""
	_guides.clear()
	queue_redraw()


func _drag_to(point: Vector2) -> void:
	if _selected < 0:
		return
	var region: Dictionary = _regions[_selected]
	var node := region["node"] as Control
	var rect: Rect2 = _drag_rect
	var delta := point - _drag_origin
	var snap := not Input.is_key_pressed(KEY_ALT)
	if _drag_mode == "move":
		var target := Vector2(rect.position.x + delta.x, rect.position.y + delta.y)
		if snap:
			target = _snap_position(region, target, rect.size)
		node.position = _normalize_rect(region, Rect2(target, rect.size)).position
	else:
		var result := _resize_rect(region, rect, delta, _drag_handle, snap)
		node.position = result.position
		node.size = result.size
		_apply_region_rules(region)
	_refresh_panel()
	queue_redraw()


## Keep a region inside the Banner Editor content rect, on integer pixels.
## The single authority on a region's geometry: at least its combined minimum, inside the
## Banner Editor content rect, integer position and size. Interactive resize, draft loads and
## nudges all pass through here so no path can produce an out-of-bounds or fractional rect.
func _normalize_rect(region: Dictionary, rect: Rect2) -> Rect2:
	var min_size: Vector2 = region["min"]
	var width := clampf(rect.size.x, min_size.x, maxf(size.x, min_size.x))
	var height := clampf(rect.size.y, min_size.y, maxf(size.y, min_size.y))
	var x := clampf(rect.position.x, 0.0, maxf(0.0, size.x - width))
	var y := clampf(rect.position.y, 0.0, maxf(0.0, size.y - height))
	return Rect2(Vector2(round(x), round(y)), Vector2(round(width), round(height)))


## Everything under a region stops taking clicks while edit mode is on.
func _go_inert(node: Node) -> void:
	if node is Control:
		(node as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in node.get_children():
		_go_inert(child)


func _resize_rect(region: Dictionary, rect: Rect2, delta: Vector2, handle: int, snap: bool) -> Rect2:
	var min_size: Vector2 = region["min"]
	var left := rect.position.x
	var top := rect.position.y
	var right := rect.end.x
	var bottom := rect.end.y
	if (handle & 1) != 0:
		left = minf(left + delta.x, right - min_size.x)
	if (handle & 2) != 0:
		right = maxf(right + delta.x, left + min_size.x)
	if (handle & 4) != 0:
		top = minf(top + delta.y, bottom - min_size.y)
	if (handle & 8) != 0:
		bottom = maxf(bottom + delta.y, top + min_size.y)
	# Corner drags keep the region's production aspect ratio, per the resize rules.
	if handle == 5 or handle == 10 or handle == 6 or handle == 9:
		var ratio: float = region["prod"].size.x / maxf(region["prod"].size.y, 1.0)
		var width := right - left
		var height := bottom - top
		if width / maxf(height, 1.0) > ratio:
			width = height * ratio
		else:
			height = width / ratio
		if (handle & 1) != 0:
			left = right - width
		else:
			right = left + width
		if (handle & 4) != 0:
			top = bottom - height
		else:
			bottom = top + height
	var result := Rect2(left, top, right - left, bottom - top)
	if snap:
		result.position = _snap_position(region, result.position, result.size)
	return _normalize_rect(region, result)


func _snap_position(region: Dictionary, target: Vector2, region_size: Vector2) -> Vector2:
	_guides.clear()
	var canvas := size
	# Candidate lines: workspace bounds and centre, every other region's edges and centres.
	var xs: Array[float] = [0.0, canvas.x * 0.5, canvas.x]
	var ys: Array[float] = [0.0, canvas.y * 0.5, canvas.y]
	var nodes := [target.x, target.x + region_size.x * 0.5, target.x + region_size.x]
	var nodeys := [target.y, target.y + region_size.y * 0.5, target.y + region_size.y]
	var best_x := INF
	var best_y := INF
	for other in _regions:
		if other == region:
			continue
		var rect: Rect2 = (other["node"] as Control).get_rect()
		xs.append(rect.position.x)
		xs.append(rect.position.x + rect.size.x * 0.5)
		xs.append(rect.end.x)
		ys.append(rect.position.y)
		ys.append(rect.position.y + rect.size.y * 0.5)
		ys.append(rect.end.y)
	var snapped := target
	for i in nodes.size():
		for line in xs:
			var d: float = line - nodes[i]
			if absf(d) <= SNAP_PX and absf(d) < absf(best_x):
				best_x = d
				_guides = _guides.filter(func(g): return not g[0])
				_guides.append([true, line])
	for i in nodeys.size():
		for line in ys:
			var d: float = line - nodeys[i]
			if absf(d) <= SNAP_PX and absf(d) < absf(best_y):
				best_y = d
				_guides = _guides.filter(func(g): return g[0])
				_guides.append([false, line])
	if best_x != INF:
		snapped.x = target.x + best_x
	else:
		snapped.x = roundf(target.x / GRID) * GRID
	if best_y != INF:
		snapped.y = target.y + best_y
	else:
		snapped.y = roundf(target.y / GRID) * GRID
	return snapped


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed:
		return
	if key.keycode == KEY_TAB:
		_selected = (_selected + 1) % maxi(_regions.size(), 1)
		_refresh_panel()
		queue_redraw()
		get_viewport().set_input_as_handled()
		return
	if key.keycode == KEY_F12:
		_screenshot()
		get_viewport().set_input_as_handled()
		return
	if _selected < 0:
		return
	var step := 5.0 if key.shift_pressed else 1.0
	var move := Vector2.ZERO
	match key.keycode:
		KEY_LEFT: move.x = -step
		KEY_RIGHT: move.x = step
		KEY_UP: move.y = -step
		KEY_DOWN: move.y = step
	if move == Vector2.ZERO:
		return
	var region: Dictionary = _regions[_selected]
	var node := region["node"] as Control
	node.position = _normalize_rect(region, Rect2(node.position + move, node.size)).position
	_refresh_panel()
	queue_redraw()
	get_viewport().set_input_as_handled()


# -------------------------------------------------------------------------------------------
# Rules: what a resize means for the region's content
# -------------------------------------------------------------------------------------------

func _apply_region_rules(region: Dictionary) -> void:
	var node := region["node"] as Control
	match String(region["name"]):
		"pole_frame":
			# The hero art rescales with the card (ratio preserved by the corner rule).
			var view := node.get_child(0) as Control
			if view != null and view.has_method("queue_redraw"):
				var scale := floorf(minf((node.size.x - 20.0) / 56.0, (node.size.y - 20.0) / 70.0) * 10.0) / 10.0
				view.set("view_scale", clampf(scale, 1.0, 12.0))
				view.queue_redraw()
		"editor_canvas":
			# The grid keeps its 16x20 cells; the display resizes by whole pixels per cell.
			var card := node.find_child("canvas_frame", true, false) as Control
			var grid := card.find_child("paint_grid", true, false) if card != null else null
			if card != null and grid is Control:
				var cells := int(floorf(minf((node.size.x - 24.0) / 16.0, (node.size.y - 56.0) / 20.0)))
				cells = clampi(cells, 4, 16)
				var display := Vector2(16.0 * cells, 20.0 * cells)
				(grid as Control).custom_minimum_size = display
				grid.set("grid_size", display)
				(grid as Control).queue_redraw()


# -------------------------------------------------------------------------------------------
# Export / draft / reset / screenshot
# -------------------------------------------------------------------------------------------

func _layout_json() -> String:
	var data := {}
	for region in _regions:
		var rect: Rect2 = (region["node"] as Control).get_rect()
		data[region["name"]] = {
			"x": int(rect.position.x), "y": int(rect.position.y),
			"w": int(rect.size.x), "h": int(rect.size.y),
		}
	# Bounds of the Banner Editor content rect, so the numbers are portable.
	data["_canvas"] = {"w": int(size.x), "h": int(size.y)}
	return JSON.stringify(data, "  ")


func _copy_layout() -> void:
	var json := _layout_json()
	DisplayServer.clipboard_set(json)
	DebugLogger.info("LAYOUTJSON|" + json.replace("\n", " "), "LayoutEdit")
	_hint.text = "Copied to clipboard and logged. Paste it to Hermes."
	print("LAYOUTJSON|" + json)


func _save_draft() -> void:
	var file := FileAccess.open(DRAFT_PATH, FileAccess.WRITE)
	if file == null:
		DebugLogger.info("layout edit: draft save failed", "LayoutEdit")
		return
	file.store_string(_layout_json())
	file.close()
	_hint.text = "Draft saved to %s" % DRAFT_PATH


func _load_draft() -> void:
	if not FileAccess.file_exists(DRAFT_PATH):
		return
	var file := FileAccess.open(DRAFT_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	for region in _regions:
		var entry = (parsed as Dictionary).get(String(region["name"]), null)
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var node := region["node"] as Control
		var rect := Rect2(node.position, node.size)
		var values := {}
		for field in ["x", "y", "w", "h"]:
			values[field] = entry.get(field, null)
		var raw_x = values["x"]
		var raw_y = values["y"]
		var raw_w = values["w"]
		var raw_h = values["h"]
		if _is_finite_number(raw_x):
			rect.position.x = float(raw_x)
		if _is_finite_number(raw_y):
			rect.position.y = float(raw_y)
		if _is_finite_number(raw_w):
			rect.size.x = float(raw_w)
		if _is_finite_number(raw_h):
			rect.size.y = float(raw_h)
		var normal := _normalize_rect(region, rect)
		node.position = normal.position
		node.size = normal.size
		_apply_region_rules(region)
	DebugLogger.info("layout edit: draft loaded", "LayoutEdit")


func _is_finite_number(value) -> bool:
	if typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_INT:
		return false
	return is_finite(float(value))


func _reset() -> void:
	for region in _regions:
		var node := region["node"] as Control
		var prod: Rect2 = region["prod"]
		node.position = prod.position
		node.size = prod.size
		_apply_region_rules(region)
	_guides.clear()
	_refresh_panel()
	queue_redraw()
	_hint.text = "Reset to the production layout."


func _screenshot() -> void:
	var image := get_viewport().get_texture().get_image()
	var path := "user://layout_edit_shot.png"
	image.save_png(path)
	DebugLogger.info("layout edit screenshot: %s" % ProjectSettings.globalize_path(path), "LayoutEdit")
	_hint.text = "Screenshot saved."


# -------------------------------------------------------------------------------------------
# Debug drawing
# -------------------------------------------------------------------------------------------

func _draw() -> void:
	# Banner Editor content bounds and centre lines - obviously dev chrome.
	draw_rect(Rect2(Vector2.ZERO, size), Color(1.0, 0.25, 0.9, 0.55), false, 2.0)
	draw_line(Vector2(size.x * 0.5, 0.0), Vector2(size.x * 0.5, size.y), Color(1.0, 0.25, 0.9, 0.18), 1.0)
	draw_line(Vector2(0.0, size.y * 0.5), Vector2(size.x, size.y * 0.5), Color(1.0, 0.25, 0.9, 0.18), 1.0)
	# Every region outlined; the selected one carries handles.
	for i in _regions.size():
		var rect: Rect2 = (_regions[i]["node"] as Control).get_rect()
		var selected := i == _selected
		var colour := Color(1.0, 0.45, 0.95, 0.95) if selected else Color(0.25, 0.85, 1.0, 0.55)
		draw_rect(rect, colour, false, 2.0 if selected else 1.0)
		var font: Font = ThemeDB.fallback_font
		draw_string(font, rect.position + Vector2(3.0, 14.0), String(_regions[i]["label"]),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, colour)
		if selected:
			for point in _handle_points(rect):
				draw_rect(Rect2(point - Vector2(HANDLE, HANDLE) * 0.5, Vector2(HANDLE, HANDLE)),
					Color(1.0, 0.45, 0.95, 0.95))
	# Snapped alignment guides.
	for guide in _guides:
		if guide[0]:
			draw_line(Vector2(guide[1], 0.0), Vector2(guide[1], size.y), Color(0.3, 1.0, 0.6, 0.7), 1.0)
		else:
			draw_line(Vector2(0.0, guide[1]), Vector2(size.x, guide[1]), Color(0.3, 1.0, 0.6, 0.7), 1.0)


func _handle_points(rect: Rect2) -> Array[Vector2]:
	var mid := rect.position + rect.size * 0.5
	return [
		rect.position, Vector2(mid.x, rect.position.y), Vector2(rect.end.x, rect.position.y),
		Vector2(rect.position.x, mid.y), Vector2(rect.end.x, mid.y),
		Vector2(rect.position.x, rect.end.y), Vector2(mid.x, rect.end.y), rect.end,
	]
