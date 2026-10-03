extends Control

## Geometry probe for the New Campaign screen (dev tool).
##
## Activated with `--layout-debug` in the user args. Waits for layout to
## settle, then prints one `LAYOUTRECT|tag|x|y|w|h` line per watched
## control and overlays each control's real rect with its name on screen.
## Read-only: it never moves anything, so what you see is the truth of
## the current layout.

const TAGS := [
	"header_panel", "rail_panel", "rail_tile_company", "rail_tile_founder",
	"company_panel", "editor_panel", "editor_controls", "editor_hero",
	"editor_canvas", "canvas_frame", "pole_frame", "editor_support", "founder_frame", "map_frame",
	"world_panel", "preview_panel", "footer_panel", "back_button",
	"start_button",
]

var _watched: Array = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	for tag in TAGS:
		var node := get_tree().root.find_child(tag, true, false)
		if node is Control:
			_watched.append([tag, node])
			var r: Rect2 = (node as Control).get_global_rect()
			DebugLogger.info("LAYOUTRECT|%s|%.1f|%.1f|%.1f|%.1f" % [tag, r.position.x, r.position.y, r.size.x, r.size.y], "LayoutDebug")
	var vp := get_viewport().get_visible_rect()
	var win := DisplayServer.window_get_size()
	DebugLogger.info("ENV|viewport=%.1fx%.1f|window=%dx%d|screen_scale=%.2f|canvas_scale=%.2f" % [vp.size.x, vp.size.y, win.x, win.y, DisplayServer.screen_get_scale(), get_viewport().get_canvas_transform().get_scale().x], "LayoutDebug")
	for tag2 in ["header_panel", "rail_panel", "editor_panel", "world_panel", "preview_panel", "footer_panel", "company_panel"]:
		var n2 := get_tree().root.find_child(tag2, true, false)
		if n2 is Control:
			var m: Vector2 = (n2 as Control).get_combined_minimum_size()
			DebugLogger.info("MIN|%s|%.1fx%.1f" % [tag2, m.x, m.y], "LayoutDebug")
	for i in range(8):
		var t := get_tree().root.find_child("rail_tile_%d" % i, true, false)
		if t is Control:
			var m2: Vector2 = (t as Control).get_combined_minimum_size()
			DebugLogger.info("MIN|rail_tile_%d|%.1fx%.1f" % [i, m2.x, m2.y], "LayoutDebug")
	for tag3 in ["banner_workspace", "editor_controls", "editor_canvas", "pole_frame", "founder_frame", "map_frame", "canvas_frame", "paint_grid"]:
		var n3 := get_tree().root.find_child(tag3, true, false)
		if n3 is Control:
			var m3: Vector2 = (n3 as Control).get_combined_minimum_size()
			DebugLogger.info("MIN2|%s|%.1fx%.1f" % [tag3, m3.x, m3.y], "LayoutDebug")
	var ws := get_tree().root.find_child("banner_workspace", true, false)
	if ws != null:
		for i2 in ws.get_child_count():
			var c2 := ws.get_child(i2)
			if c2 is Control:
				var m4: Vector2 = (c2 as Control).get_combined_minimum_size()
				DebugLogger.info("MIN2|lane%d:%s|%.1fx%.1f" % [i2, c2.name, m4.x, m4.y], "LayoutDebug")
	_dump_tree()
	queue_redraw()


## Every Control under the screen, path-labelled, one line each, so art
## requests can be specced against measured boxes rather than eyeballs.
func _dump_tree() -> void:
	var screen := get_parent()
	if screen == null:
		return
	_walk(screen, "screen")


func _walk(node: Node, prefix: String) -> void:
	for child in node.get_children():
		if child is Control:
			var label := prefix + "/" + str(child.name) + ":" + child.get_class()
			var r: Rect2 = (child as Control).get_global_rect()
			DebugLogger.info("TREERECT|%s|%.1f|%.1f|%.1f|%.1f" % [label, r.position.x, r.position.y, r.size.x, r.size.y], "LayoutDebug")
			_walk(child, label)


func _draw() -> void:
	var font: Font = ThemeDB.fallback_font
	for pair in _watched:
		var tag: String = pair[0]
		var ctl := pair[1] as Control
		var r := ctl.get_global_rect()
		draw_rect(r, Color(1.0, 0.25, 0.9, 0.9), false, 1.0)
		draw_string(font, r.position + Vector2(2.0, -3.0), tag, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1.0, 0.4, 0.95, 1.0))
