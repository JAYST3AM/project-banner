extends Control
## Standalone visual acceptance harness for M02 Slice B1.
## Synthetic display data only: it does not launch a battle or issue simulation orders.
const FIELD := Vector2(260.0, 130.0)
const SCREENSHOT_PROBE := preload("res://scripts/dev/screenshot_probe.gd")
const PREVIEW_MODE_PREFIX := "--preview-mode="

var _world: Node2D
var _command: BattleCommandBar
var _overview: BattleTacticalOverview
var _formations: Array[Dictionary] = []
var _full_map := true


func _ready() -> void:
	_full_map = _requested_full_map()
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
	]
	_overview.set_formations(_formations, [1], 4, _full_map)
	_command = BattleCommandBar.new()
	add_child(_command)
	_command.set_battle_status(false, 50, 39, 1, true, false)
	var title := Label.new()
	title.text = "M02 / B1 — COMPONENT PREVIEW (M: TOGGLE MAP / MEDIUM)"
	title.add_theme_color_override("font_color", Color("e9e6dc"))
	title.add_theme_font_size_override("font_size", 16)
	title.position = Vector2(24, 12)
	add_child(title)
	resized.connect(_layout)
	_layout()
	_spawn_screenshot_probe()


## Deterministic capture mode; no synthetic keyboard events required.
## Example: -- --preview-mode=medium --screenshot=... --screenshot-quit
func _requested_full_map() -> bool:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(PREVIEW_MODE_PREFIX):
			var mode := arg.trim_prefix(PREVIEW_MODE_PREFIX).to_lower()
			if mode == "medium":
				return false
			if mode == "full":
				return true
			push_warning("Unknown --preview-mode=%s; using full map" % mode)
	return true


## The boot scene is bypassed for direct dev-scene launches. Install the existing
## root-level probe here only when a screenshot was explicitly requested; this
## leaves the game's production boot and autoload configuration untouched.
func _spawn_screenshot_probe() -> void:
	if DevFlags.screenshot_path().is_empty():
		return
	if get_tree().root.get_node_or_null("ScreenshotProbe") != null:
		return
	var probe := Node.new()
	probe.name = "ScreenshotProbe"
	probe.set_script(SCREENSHOT_PROBE)
	get_tree().root.add_child.call_deferred(probe)


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
