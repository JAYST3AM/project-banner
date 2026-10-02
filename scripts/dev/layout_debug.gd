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
	"company_panel", "editor_panel", "editor_controls", "canvas_frame",
	"editor_previews", "pole_frame", "founder_frame", "map_frame",
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
	queue_redraw()


func _draw() -> void:
	var font: Font = ThemeDB.fallback_font
	for pair in _watched:
		var tag: String = pair[0]
		var ctl := pair[1] as Control
		var r := ctl.get_global_rect()
		draw_rect(r, Color(1.0, 0.25, 0.9, 0.9), false, 1.0)
		draw_string(font, r.position + Vector2(2.0, -3.0), tag, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1.0, 0.4, 0.95, 1.0))
