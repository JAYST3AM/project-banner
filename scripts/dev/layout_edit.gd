class_name LayoutEditLayer
extends Control
## Dev-only layout editor for ANY screen (activated by [code]--layout-edit[/code]).
##
## The watcher (scripts/dev/layout_edit_watcher.gd) attaches one of these to
## whatever screen is current and re-attaches when the screen changes, so
## every window in the game can be composed by hand. The screen's production
## containers are dismantled and the editable elements are reparented into
## this manual layer, where their rects can genuinely be dragged and resized
## (no container overwrites them):
##
## - the named panel regions of the New Campaign screen (tools cluster, edit
##   canvas, banner hero, founder slot, map, company details, world settings,
##   campaign preview) when present, and
## - every button and text input on the screen, individually.
##
## Controls that were inside a named region stay linked to it: dragging the
## region carries its buttons along (the shared delta is clamped so the whole
## group stays inside the content area), while dragging a button on its own
## moves just that button. The arrangement exports as JSON per screen; drafts
## persist under user://layout_drafts/.
##
## Keys: H hides/shows the panel, arrows nudge 1px, Shift+arrows 5px, Tab
## cycles, Alt during a drag ignores snapping, C copies, S saves, R resets,
## F12 drops a screenshot into user://. The geometry normalizer is the single
## authority: minimum sizes, content bounds, integer rects. Everything still
## renders for real - the banner waves, the grid shows the paint.

const DRAFT_DIR := "user://layout_drafts"
const LEGACY_DRAFT := "user://banner_layout_draft.json"
const HANDLE := 7.0
const GRID := 2.0
const SNAP_PX := 6.0

## Named panel regions: found by node name when the screen has them (the New
## Campaign screen does); other screens simply contribute buttons and inputs.
const REGION_NAMES: Array[String] = [
	"editor_controls", "editor_canvas", "pole_frame", "founder_frame", "map_frame",
	"company_panel", "world_panel", "preview_panel", "rail_panel",
]
const REGION_LABELS := {
	"editor_controls": "ToolsCluster",
	"editor_canvas": "EditCanvas",
	"pole_frame": "HeroBanner",
	"founder_frame": "Founder",
	"map_frame": "MapPreview",
	"company_panel": "CompanyDetails",
	"world_panel": "WorldSettings",
	"preview_panel": "CampaignPreview",
	"rail_panel": "LeftRail",
}

## Node-name prefixes that mark additional editable elements on any screen
## (the New Campaign rail names its step tiles this way).
const NAMED_PREFIXES: Array[String] = ["rail_tile"]

var _regions: Array = []          # [{name, label, node, prod, min, links, parent}]
var _selected := -1
var _hover := -1
var _drag_mode := ""              # "", "move", "resize"
var _drag_handle := -1
var _handle_region := -1
var _drag_origin := Vector2.ZERO
var _drag_rect := Rect2()
var _drag_members: Array = []     # [{node, start: Vector2}] captured at press
var _guides: Array = []           # [[vertical: bool, coord: float]]
var _panel: PanelContainer = null
var _info: Label = null
var _hint: Label = null
var _panel_hidden := false
var _editor_rect := Rect2()
var _screen: Node = null
var _draft_key := "screen"


# -------------------------------------------------------------------------------------------
# Activation
# -------------------------------------------------------------------------------------------

## Take over a screen: discover the editable elements, flatten them into this
## layer, and hand the arrangement to the user.
func start(screen: Node, host_override: Control = null) -> void:
	_screen = screen
	name = "layout_edit_layer"
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	var host: Control = host_override
	if host == null and screen is Control:
		host = screen as Control
		for child in (screen as Control).get_children():
			if child is MarginContainer:
				host = child
				break
	if host == null:
		return
	host.add_child(self)
	set_anchors_preset(Control.PRESET_FULL_RECT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_draft_key = _scene_key(screen)
	await get_tree().process_frame
	await get_tree().process_frame
	# The anchors do their job under Control hosts; under a canvas host (Node2D
	# screens) size the layer explicitly so the geometry authority never runs
	# against a zero rect.
	if size.x < 1.0 or size.y < 1.0:
		position = Vector2.ZERO
		size = host.size

	var origin := global_position
	var workspace := screen.find_child("banner_workspace", true, false) as Control
	if workspace != null:
		_editor_rect = Rect2(workspace.global_position - origin, workspace.size)
	_pin_shells(screen, workspace)
	_discover(screen, origin)
	_free_emptied_shells(screen)

	_build_panel()
	await get_tree().process_frame
	await get_tree().process_frame
	_layout_panel()
	_load_draft()
	_refresh_panel()
	DebugLogger.info("layout edit active on '%s': %d elements, area %dx%d" % [
		_draft_key, _regions.size(), int(size.x), int(size.y)], "LayoutEdit")
	if DevFlags.layout_export():
		_copy_layout()


func _scene_key(screen: Node) -> String:
	var key := String(screen.name).to_snake_case()
	if key.is_empty():
		key = "screen"
	return key.validate_filename()


## The production shells stay in place (pinned to their current size) so the
## screen does not reflow behind the floating elements.
func _pin_shells(screen: Node, workspace: Control) -> void:
	if workspace != null:
		workspace.size_flags_vertical = Control.SIZE_EXPAND_FILL
		workspace.custom_minimum_size = workspace.size
	var editor := screen.find_child("editor_panel", true, false) as Control
	if editor != null:
		editor.custom_minimum_size = editor.size


func _discover(screen: Node, origin: Vector2) -> void:
	var seen := {}
	var queue: Array[Control] = []
	# 1. The named panel regions, if this screen has them.
	for region_name in REGION_NAMES:
		var node := screen.find_child(region_name, true, false) as Control
		if node == null or _inside_layer(node) or seen.has(node):
			continue
		queue.append(node)
		seen[node] = REGION_LABELS.get(region_name, region_name)
	# 2. Anything whose name carries a known editable prefix.
	for prefix in NAMED_PREFIXES:
		for node in screen.find_children(prefix + "*", "", true, false):
			var control := node as Control
			if control == null or _inside_layer(control) or seen.has(control):
				continue
			queue.append(control)
			seen[control] = _panel_label(control)
	# 3. Every button and text input, individually.
	_collect_interactives(screen, queue, seen)
	# Build the region table (parents first, so links refer to the original tree).
	var by_node := {}
	var taken := {}
	for node in queue:
		var region := {
			"name": _unique_key(node, taken),
			"label": seen[node],
			"node": node,
			"prod": Rect2(node.global_position - origin, node.size),
			"min": node.get_combined_minimum_size(),
			"links": [] as Array[int],
			"parent": null,
		}
		taken[region["name"]] = true
		by_node[node] = region
	for node in queue:
		by_node[node]["parent"] = _nearest_included(node, by_node)
	# Reparent and record.
	for node in queue:
		var region: Dictionary = by_node[node]
		var local: Rect2 = region["prod"]
		node.reparent(self)
		node.position = local.position
		node.size = local.size
		_go_inert(node)
		_regions.append(region)
	# Link bookkeeping: every extracted control points at its nearest extracted
	# ancestor so group drags can carry it.
	for i in _regions.size():
		var parent_node = _regions[i]["parent"]
		if parent_node != null and by_node.has(parent_node):
			var parent_region: Dictionary = by_node[parent_node]
			var parent_index: int = _regions.find(parent_region)
			if parent_index >= 0:
				(parent_region["links"] as Array).append(i)


func _inside_layer(node: Control) -> bool:
	var walker: Node = node
	while walker != null:
		if walker == self:
			return true
		walker = walker.get_parent()
	return false


func _collect_interactives(root: Node, queue: Array[Control], seen: Dictionary) -> void:
	for child in root.get_children():
		if child == self:
			continue
		if child is BaseButton or child is LineEdit:
			var control := child as Control
			if not seen.has(control) and control.is_visible_in_tree():
				queue.append(control)
				seen[control] = _label_for(control)
			continue
		_collect_interactives(child, queue, seen)


func _label_for(control: Control) -> String:
	var text := ""
	if control is Button:
		text = String((control as Button).text).strip_edges()
		if text.is_empty() and not String(control.tooltip_text).is_empty():
			# Icon buttons carry their name in the tooltip ("Pencil - click ...").
			text = String(control.tooltip_text).split(" - ")[0].strip_edges()
	elif control is LineEdit:
		text = "Input"
	if text.is_empty():
		text = _name_base(control)
	return text.substr(0, 22)


## A readable base for a control's key; Godot's automatic names ("@Button@90",
## "@LineEdit@81") are replaced with something a human can read back.
func _name_base(control: Control) -> String:
	var raw := String(control.name)
	if raw.begins_with("@"):
		var kind := "control"
		if control is BaseButton:
			kind = "button"
		elif control is LineEdit:
			kind = "input"
		return "%s_%d" % [kind, control.get_index()]
	return raw


## A readable label for panel-like elements (the rail tiles): the first text
## label inside them, else the name.
func _panel_label(control: Control) -> String:
	var walker: Array[Node] = [control]
	var depth := 0
	while walker.size() > 0 and depth < 24:
		var node: Node = walker.pop_front()
		for child in node.get_children():
			if child is Label:
				var text := String((child as Label).text).strip_edges()
				if not text.is_empty():
					return text.substr(0, 22)
			walker.append(child)
			depth += 1
	return _name_base(control).capitalize()


func _nearest_included(node: Node, by_node: Dictionary) -> Control:
	var walker := node.get_parent()
	while walker != null:
		if by_node.has(walker):
			return walker as Control
		walker = walker.get_parent()
	return null


func _unique_key(node: Control, taken: Dictionary) -> String:
	var base := _name_base(node).to_snake_case()
	if base.is_empty():
		base = "control"
	var key := base
	var n := 1
	while taken.has(key):
		n += 1
		key = "%s_%d" % [base, n]
	return key


## Containers the extraction emptied are removed, so the pinned backdrop and
## the floating elements are all that remains.
func _free_emptied_shells(screen: Node) -> void:
	var walker: Array[Node] = [screen]
	var emptied: Array[Node] = []
	while walker.size() > 0:
		var node: Node = walker.pop_back()
		for child in node.get_children():
			walker.append(child)
			if child is Container and not _is_region_node(child):
				var has_control := false
				for grandchild in (child as Container).get_children():
					if grandchild is Control:
						has_control = true
						break
				if not has_control:
					emptied.append(child)
	for shell in emptied:
		if _inside_layer(shell as Control) or _is_region_node(shell):
			continue
		shell.queue_free()


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
	_panel.name = "layout_edit_panel"
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
	title.text = "LAYOUT EDIT (dev - %s)" % _draft_key
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
	_hint.text = "H: hide panel | click: select | drag: move | edge/corner: resize\nalt: no snap | arrows: 1px, shift+arrows: 5px | tab: cycle | C copy, S save, R reset, F12 shot"
	_hint.add_theme_color_override("font_color", Color(0.75, 0.75, 0.8))
	rows.add_child(_hint)


func _add_button(row: HBoxContainer, text: String, handler: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(handler)
	row.add_child(button)


func _layout_panel() -> void:
	_panel.position = Vector2(24.0, maxf(8.0, size.y - _panel.size.y - 8.0))


func _refresh_panel() -> void:
	if _info == null:
		return
	if _selected < 0 or _selected >= _regions.size():
		_info.text = "Selected: -   (%d elements)" % _regions.size()
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
	if motion != null:
		if _drag_mode != "":
			_drag_to(motion.position)
		else:
			var hit := _hit_region(motion.position)
			if hit != _hover:
				_hover = hit
				queue_redraw()
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
	_drag_members.clear()
	if _drag_mode == "move":
		var node := _regions[_selected]["node"] as Control
		_drag_members.append({"node": node, "start": node.position})
		for link in linked_indices(_selected):
			var linked := _regions[link]["node"] as Control
			_drag_members.append({"node": linked, "start": linked.position})
	_refresh_panel()
	queue_redraw()


## Handles belong to elements with room for them: anything smaller than 40 on
## either axis is move-only, and the margin shrinks with tiny controls, so a
## press inside a small button can never be mistaken for a resize grab.
func _handle_at(point: Vector2) -> int:
	for i in _regions.size():
		var rect: Rect2 = (_regions[i]["node"] as Control).get_rect()
		if rect.size.x < 40.0 or rect.size.y < 40.0:
			continue
		var margin := minf(HANDLE, minf(rect.size.x, rect.size.y) / 3.0)
		if not rect.grow(margin).has_point(point):
			continue
		var handle := 0
		if point.x <= rect.position.x + margin:
			handle |= 1
		elif point.x >= rect.end.x - margin:
			handle |= 2
		if point.y <= rect.position.y + margin:
			handle |= 4
		elif point.y >= rect.end.y - margin:
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
	var rect: Rect2 = _drag_rect
	var delta := point - _drag_origin
	var snap := not Input.is_key_pressed(KEY_ALT)
	if _drag_mode == "move":
		var target := Vector2(rect.position.x + delta.x, rect.position.y + delta.y)
		if snap:
			target = _snap_position(region, target, rect.size)
		target = _normalize_rect(region, Rect2(target, rect.size)).position
		_move_members(target - rect.position)
	else:
		var result := _resize_rect(region, rect, delta, _drag_handle, snap)
		var node := region["node"] as Control
		node.position = result.position
		node.size = result.size
		_apply_region_rules(region)
	_refresh_panel()
	queue_redraw()


## Move the press-time member set (the region and its linked descendants) by
## an absolute delta from their captured press positions; the shared delta is
## clamped per axis against every member's start rect, so the whole group
## stays inside the content area and repeated motion events cannot compound.
func _move_members(wanted: Vector2) -> void:
	var delta := wanted
	for axis in 2:
		var allowed := delta[axis]
		for member in _drag_members:
			var start: Vector2 = member["start"]
			var node := member["node"] as Control
			if delta[axis] > 0.0:
				allowed = minf(allowed, size[axis] - (start[axis] + node.size[axis]))
			elif delta[axis] < 0.0:
				allowed = maxf(allowed, -start[axis])
		delta[axis] = allowed
	for member in _drag_members:
		var node := member["node"] as Control
		node.position = ((member["start"] as Vector2) + delta).round()
	for member in _drag_members:
		_apply_node_rules(member["node"] as Control)


## Nudge path: same bookkeeping for a one-shot move of the selection.
func _move_with_links(index: int, wanted: Vector2) -> void:
	_drag_members.clear()
	var node := _regions[index]["node"] as Control
	_drag_members.append({"node": node, "start": node.position})
	for link in linked_indices(index):
		var linked := _regions[link]["node"] as Control
		_drag_members.append({"node": linked, "start": linked.position})
	_move_members(wanted)


## True while a node is part of the group being dragged; its live position is
## not a snap candidate mid-drag, so repeated pointer events snap identically.
func _is_drag_member(node: Control) -> bool:
	for member in _drag_members:
		if member["node"] == node:
			return true
	return false


## Per-node rules (hero rescale, canvas cells) by reverse lookup.
func _apply_node_rules(node: Control) -> void:
	for region in _regions:
		if region["node"] == node:
			_apply_region_rules(region)
			return


## Every extracted descendant of a region, including grandchildren.
func linked_indices(index: int) -> Array[int]:
	var members: Array[int] = []
	var direct: Array = (_regions[index]["links"] as Array).duplicate()
	members.append_array(direct)
	var walker := 0
	while walker < members.size():
		var child: int = members[walker]
		for grand in (_regions[child]["links"] as Array):
			if not members.has(grand):
				members.append(grand)
		walker += 1
	return members


## The single authority on a region's geometry: at least its combined minimum,
## inside the content area, integer position and size. Interactive resize,
## draft loads, group moves and nudges all pass through here.
func _normalize_rect(region: Dictionary, rect: Rect2) -> Rect2:
	var min_size: Vector2 = region["min"]
	# Integer-exact: use rounded layer dimensions, round the requested size up
	# to its minimum, cap at the layer (even when a minimum exceeds it - a
	# region that cannot fit still has to stay on screen), then clamp the
	# position against the rounded values so the final edge is always inside.
	# A layer thinner than one pixel cannot host regions at all; the 1px floor
	# keeps the arithmetic sane in a state that start() already prevents.
	var lw := maxf(1.0, roundf(size.x))
	var lh := maxf(1.0, roundf(size.y))
	var width := minf(roundf(maxf(rect.size.x, min_size.x)), lw)
	var height := minf(roundf(maxf(rect.size.y, min_size.y)), lh)
	var x := clampf(roundf(rect.position.x), 0.0, lw - width)
	var y := clampf(roundf(rect.position.y), 0.0, lh - height)
	return Rect2(Vector2(x, y), Vector2(width, height))


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
	# Corner drags keep the aspect of substantial panels; small controls resize freely.
	var substantial: bool = rect.size.x >= 100.0 and rect.size.y >= 50.0
	var corner: bool = handle == 5 or handle == 10 or handle == 6 or handle == 9
	if substantial and corner:
		var ratio: float = rect.size.x / maxf(rect.size.y, 1.0)
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
	var xs: Array[float] = [0.0, canvas.x * 0.5, canvas.x]
	var ys: Array[float] = [0.0, canvas.y * 0.5, canvas.y]
	if _editor_rect.size.x > 0.0:
		xs.append(_editor_rect.position.x)
		xs.append(_editor_rect.position.x + _editor_rect.size.x * 0.5)
		xs.append(_editor_rect.end.x)
		ys.append(_editor_rect.position.y)
		ys.append(_editor_rect.position.y + _editor_rect.size.y * 0.5)
		ys.append(_editor_rect.end.y)
	var nodes := [target.x, target.x + region_size.x * 0.5, target.x + region_size.x]
	var nodeys := [target.y, target.y + region_size.y * 0.5, target.y + region_size.y]
	var best_x := INF
	var best_y := INF
	for other in _regions:
		if other == region or _is_drag_member(other["node"] as Control):
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
	match key.keycode:
		KEY_H:
			_panel_hidden = not _panel_hidden
			_panel.visible = not _panel_hidden
			queue_redraw()
			get_viewport().set_input_as_handled()
			return
		KEY_TAB:
			_selected = (_selected + 1) % maxi(_regions.size(), 1)
			_refresh_panel()
			queue_redraw()
			get_viewport().set_input_as_handled()
			return
		KEY_F12:
			_screenshot()
			get_viewport().set_input_as_handled()
			return
		KEY_C:
			_copy_layout()
			get_viewport().set_input_as_handled()
			return
		KEY_S:
			_save_draft()
			get_viewport().set_input_as_handled()
			return
		KEY_R:
			_reset()
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
	var nudged := _normalize_rect(region, Rect2(node.position + move, node.size)).position
	_move_with_links(_selected, nudged - node.position)
	_refresh_panel()
	queue_redraw()
	get_viewport().set_input_as_handled()


# -------------------------------------------------------------------------------------------
# Rules: what a resize means for the region's content
# -------------------------------------------------------------------------------------------

func _apply_region_rules(region: Dictionary) -> void:
	var node := region["node"] as Control
	match String(region["name"]).to_snake_case():
		"pole_frame":
			# The hero art rescales with the card.
			var view := node.get_child(0) as Control
			if view != null and view.has_method("queue_redraw"):
				var scale := floorf(minf((node.size.x - 20.0) / 56.0, (node.size.y - 20.0) / 70.0) * 10.0) / 10.0
				view.set("view_scale", clampf(scale, 1.0, 12.0))
				view.queue_redraw()
		"editor_canvas":
			# The grid keeps its 16x20 cells; the display resizes by whole pixels per cell.
			var card := node.find_child("canvas_frame", true, false) as Control
			var grid_node := card.find_child("paint_grid", true, false) if card != null else null
			if card != null and grid_node is Control:
				var cells := int(floorf(minf((node.size.x - 24.0) / 16.0, (node.size.y - 56.0) / 20.0)))
				cells = clampi(cells, 4, 16)
				var display := Vector2(16.0 * cells, 20.0 * cells)
				(grid_node as Control).custom_minimum_size = display
				grid_node.set("grid_size", display)
				(grid_node as Control).queue_redraw()


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
	data["_screen"] = {"w": int(size.x), "h": int(size.y),
		"x": int(global_position.x), "y": int(global_position.y)}
	if _editor_rect.size.x > 0.0:
		data["_editor"] = {
			"x": int(_editor_rect.position.x), "y": int(_editor_rect.position.y),
			"w": int(_editor_rect.size.x), "h": int(_editor_rect.size.y),
		}
	return JSON.stringify(data, "  ")


func _copy_layout() -> void:
	var json := _layout_json()
	DisplayServer.clipboard_set(json)
	DebugLogger.info("LAYOUTJSON|" + json.replace("\n", " "), "LayoutEdit")
	_hint.text = "Copied to clipboard and logged. Paste it to Hermes."
	print("LAYOUTJSON|" + json)


func _draft_path() -> String:
	return "%s/%s.json" % [DRAFT_DIR, _draft_key]


func _save_draft() -> void:
	DirAccess.make_dir_recursive_absolute(DRAFT_DIR)
	var file := FileAccess.open(_draft_path(), FileAccess.WRITE)
	if file == null:
		DebugLogger.info("layout edit: draft save failed", "LayoutEdit")
		return
	file.store_string(_layout_json())
	file.close()
	_hint.text = "Draft saved to %s" % _draft_path()


func _load_draft() -> void:
	var path := _draft_path()
	var used_legacy := false
	if not FileAccess.file_exists(path):
		# Adopt the pre-watcher single-screen draft for the New Campaign screen.
		if _draft_key == "new_campaign" and FileAccess.file_exists(LEGACY_DRAFT):
			path = LEGACY_DRAFT
			used_legacy = true
		else:
			return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	# Drafts from before the screen-space rework stored the five editor regions
	# relative to the Banner Editor content rect; shift them into place.
	var legacy: bool = used_legacy and not (parsed as Dictionary).has("_screen")
	var offset: Vector2 = _editor_rect.position if legacy else Vector2.ZERO
	for region in _regions:
		var entry = (parsed as Dictionary).get(String(region["name"]), null)
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var node := region["node"] as Control
		var rect := Rect2(node.position, node.size)
		var values := {}
		for field in ["x", "y", "w", "h"]:
			values[field] = entry.get(field, null)
		if _is_finite_number(values["x"]):
			rect.position.x = float(values["x"]) + offset.x
		if _is_finite_number(values["y"]):
			rect.position.y = float(values["y"]) + offset.y
		if _is_finite_number(values["w"]):
			rect.size.x = float(values["w"])
		if _is_finite_number(values["h"]):
			rect.size.y = float(values["h"])
		var normal := _normalize_rect(region, rect)
		node.position = normal.position
		node.size = normal.size
		_apply_region_rules(region)
	DebugLogger.info("layout edit: draft loaded (%s)" % path, "LayoutEdit")


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
	var path := "user://layout_edit_shot_%s.png" % _draft_key
	image.save_png(path)
	DebugLogger.info("layout edit screenshot: %s" % ProjectSettings.globalize_path(path), "LayoutEdit")
	_hint.text = "Screenshot saved."


# -------------------------------------------------------------------------------------------
# Debug drawing
# -------------------------------------------------------------------------------------------

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(1.0, 0.25, 0.9, 0.35), false, 2.0)
	if _editor_rect.size.x > 0.0:
		draw_rect(_editor_rect, Color(1.0, 0.25, 0.9, 0.6), false, 2.0)
		draw_string(ThemeDB.fallback_font, _editor_rect.position + Vector2(3.0, -6.0), "BANNER EDITOR",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1.0, 0.45, 0.95))
		draw_line(Vector2(_editor_rect.position.x + _editor_rect.size.x * 0.5, _editor_rect.position.y),
			Vector2(_editor_rect.position.x + _editor_rect.size.x * 0.5, _editor_rect.end.y),
			Color(1.0, 0.25, 0.9, 0.18), 1.0)
		draw_line(Vector2(_editor_rect.position.x, _editor_rect.position.y + _editor_rect.size.y * 0.5),
			Vector2(_editor_rect.end.x, _editor_rect.position.y + _editor_rect.size.y * 0.5),
			Color(1.0, 0.25, 0.9, 0.18), 1.0)
	var font: Font = ThemeDB.fallback_font
	for i in _regions.size():
		var rect: Rect2 = (_regions[i]["node"] as Control).get_rect()
		var selected := i == _selected
		var hovered := i == _hover
		var colour := Color(1.0, 0.45, 0.95, 0.95) if selected else Color(0.25, 0.85, 1.0, 0.45)
		if hovered and not selected:
			colour = Color(0.25, 0.85, 1.0, 0.9)
		draw_rect(rect, colour, false, 2.0 if selected else 1.0)
		if selected or hovered:
			draw_string(font, rect.position + Vector2(3.0, 14.0), String(_regions[i]["label"]),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 12, colour)
		if selected:
			for point in _handle_points(rect):
				draw_rect(Rect2(point - Vector2(HANDLE, HANDLE) * 0.5, Vector2(HANDLE, HANDLE)),
					Color(1.0, 0.45, 0.95, 0.95))
	for guide in _guides:
		if guide[0]:
			draw_line(Vector2(guide[1], 0.0), Vector2(guide[1], size.y), Color(0.3, 1.0, 0.6, 0.7), 1.0)
		else:
			draw_line(Vector2(0.0, guide[1]), Vector2(size.x, guide[1]), Color(0.3, 1.0, 0.6, 0.7), 1.0)
	if _panel_hidden:
		draw_string(font, Vector2(24.0, 30.0), "layout edit - H shows the panel (%d elements)" % _regions.size(),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1.0, 0.45, 0.95, 0.85))


func _handle_points(rect: Rect2) -> Array[Vector2]:
	var mid := rect.position + rect.size * 0.5
	return [
		rect.position, Vector2(mid.x, rect.position.y), Vector2(rect.end.x, rect.position.y),
		Vector2(rect.position.x, mid.y), Vector2(rect.end.x, mid.y),
		Vector2(rect.position.x, rect.end.y), Vector2(mid.x, rect.end.y), rect.end,
	]
