extends Node2D
## Battle scene controller.
##
## Receives a [BattleContext] through the scene payload and does nothing else with
## global state: the armies, the ground and the seeds all arrive in the context.
## It owns the camera, forwards input into the simulator, and draws the HUD.

@onready var _view: BattleView = $View
@onready var _camera: Camera2D = $Camera2D

var _context: BattleContext = null
var _simulator: BattleSimulator = null
var _config: GameConfig = null

var _enemy_party_id: String = ""

var _title: Label = null
var _info: Label = null
var _hint: Label = null
var _start_button: Button = null
var _retreat_button: Button = null
var _info_timer: float = 0.0

var _panning := false
var _box_selecting := false
var _box_start_world := Vector2.ZERO
var _box_current_world := Vector2.ZERO
var _drag_threshold_px := 6.0
var _resolved := false
## Battle-time multiplier used by automated runs (DevFlags.battle_speed()).
var _battle_speed := 1.0


func _ready() -> void:
	_config = GameManager.config()
	_context = SceneManager.consume_payload().get("context") as BattleContext

	if _context == null:
		DebugLogger.error("battle scene opened without a BattleContext", "Battle")
		SceneManager.change_scene("world_map")
		return

	DebugLogger.info("battle loading: %s" % _context.summary(), "Battle")

	var units := BattleSetup.build_units(_context)
	BattleSetup.deploy(units, _config)

	_simulator = BattleSimulator.new(_config, _context.battle_seed)
	_simulator.add_units(units)
	_view.bind(_simulator, _context)

	var roster: Array[String] = []
	for unit in units:
		roster.append("%s:%s" % [unit.side, unit.display_name])
	DebugLogger.info("deployed %d player and %d enemy units: %s" % [
		_simulator.side_count(BattleContext.SIDE_PLAYER),
		_simulator.side_count(BattleContext.SIDE_ENEMY),
		", ".join(roster),
	], "Battle")

	_focus_camera()
	_build_hud()
	_refresh()
	set_process(true)

	_battle_speed = DevFlags.battle_speed()
	if DevFlags.autostart_battle():
		DebugLogger.info("dev flag: starting the battle automatically", "Battle")
		call_deferred("_on_start_battle")


func _focus_camera() -> void:
	var size := _simulator.field_size
	_camera.position = size * 0.5
	_camera.zoom = Vector2(9.0, 9.0)


## ---------- HUD ----------------------------------------------------------

func _build_hud() -> void:
	var hud := CanvasLayer.new()
	hud.layer = 10
	add_child(hud)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UiTheme.panel_style(UiTheme.PANEL_DEEP))
	panel.position = Vector2(12.0, 12.0)
	hud.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	panel.add_child(box)

	_title = UiTheme.label("", 22, UiTheme.GOLD)
	box.add_child(_title)
	box.add_child(UiTheme.heading_rule())
	_info = UiTheme.label("", 14, UiTheme.TEXT)
	box.add_child(_info)

	var hint_panel := PanelContainer.new()
	hint_panel.add_theme_stylebox_override("panel", UiTheme.panel_style(UiTheme.PANEL_DEEP))
	hint_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	hint_panel.position = Vector2(-430.0, 12.0)
	hint_panel.custom_minimum_size = Vector2(418.0, 0.0)
	hud.add_child(hint_panel)
	_hint = UiTheme.label("", 13, UiTheme.DIM)
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.custom_minimum_size = Vector2(392.0, 0.0)
	hint_panel.add_child(_hint)

	var actions := PanelContainer.new()
	actions.add_theme_stylebox_override("panel", UiTheme.panel_style())
	actions.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	actions.position = Vector2(12.0, -58.0)
	hud.add_child(actions)
	var action_box := HBoxContainer.new()
	action_box.add_theme_constant_override("separation", 8)
	actions.add_child(action_box)

	_start_button = UiTheme.button("Start Battle", 130.0)
	_start_button.pressed.connect(_on_start_battle)
	action_box.add_child(_start_button)

	_retreat_button = UiTheme.button("Retreat", 110.0)
	_retreat_button.pressed.connect(_on_retreat)
	action_box.add_child(_retreat_button)

	if OS.is_debug_build():
		var leave := UiTheme.button("Debug Exit", 110.0)
		leave.tooltip_text = "Leave the battlefield without resolving it (debug builds only)"
		leave.pressed.connect(_on_debug_exit)
		action_box.add_child(leave)


func _refresh() -> void:
	if _context == null or _simulator == null:
		return
	_title.text = "%s  -  %s" % [_context.enemy_display_name, _context.battle_id]
	_info.text = "\n".join([
		"Your force:   %d standing  (strength %d)" % [
			_simulator.side_count(BattleContext.SIDE_PLAYER), _context.strength_of(BattleContext.SIDE_PLAYER),
		],
		"Enemy force:  %d standing  (strength %d)" % [
			_simulator.side_count(BattleContext.SIDE_ENEMY), _context.strength_of(BattleContext.SIDE_ENEMY),
		],
		"Ground:       %s, seed %d" % [_context.weather, _context.terrain_seed],
		"Time:         Day %d %s   (elapsed %d:%02d)" % [
			_context.campaign_day,
			CampaignClock.time_string_from_hour(_context.campaign_hour),
			int(_simulator.elapsed) / 60,
			int(_simulator.elapsed) % 60,
		],
		"Battle state: %s" % _state_name(),
	])
	_start_button.disabled = _simulator.is_running()
	var selected := _view.selected_ids.size()
	_retreat_button.text = "Retreat" if selected == 0 else "Retreat (%d selected)" % selected


func _state_name() -> String:
	match _simulator.state:
		BattleSimulator.State.DEPLOYING:
			return "deployed, awaiting your order"
		BattleSimulator.State.RUNNING:
			return "engaged"
		_:
			return "over"


## ---------- per-frame ----------------------------------------------------

func _process(delta: float) -> void:
	if _simulator == null:
		return
	_update_camera_pan(delta)
	if _simulator.is_running():
		var events := _simulator.step(delta * _battle_speed)
		_view.add_events(events)
		_view.queue_redraw()
		_info_timer += delta
		if _info_timer >= 0.25:
			_info_timer = 0.0
			_refresh()
		if _simulator.is_finished():
			_resolve_and_show(false)


## ---------- camera and input --------------------------------------------

func _update_camera_pan(delta: float) -> void:
	var direction := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		direction.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		direction.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		direction.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		direction.y += 1.0
	if direction == Vector2.ZERO:
		return
	var speed := _config.get_float("world.camera_pan_speed", 700.0) / maxf(0.2, _camera.zoom.x)
	_camera.position += direction.normalized() * speed * delta
	_clamp_camera()


func _clamp_camera() -> void:
	var size := _simulator.field_size if _simulator != null else Vector2(100.0, 60.0)
	_camera.position = Vector2(
		clampf(_camera.position.x, 0.0, size.x),
		clampf(_camera.position.y, 0.0, size.y)
	)


func _unhandled_input(event: InputEvent) -> void:
	if _simulator == null:
		return

	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_by(1.12)
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_by(1.0 / 1.12)
		elif button.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = button.pressed
		elif button.button_index == MOUSE_BUTTON_LEFT:
			if button.pressed:
				_begin_box_select()
			else:
				_finish_box_select(button.shift_pressed)
		elif button.pressed and button.button_index == MOUSE_BUTTON_RIGHT:
			_issue_move_order(_view.get_global_mouse_position())
		return

	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _panning:
			_camera.position -= motion.relative / _camera.zoom
			_clamp_camera()
		elif _box_selecting:
			_box_current_world = _view.get_global_mouse_position()
			_view.box_select_active = true
			_view.box_select_rect = _world_rect(_box_start_world, _box_current_world)
			_view.queue_redraw()
		return

	if event is InputEventKey and event.pressed and not event.echo:
		_handle_key(event as InputEventKey)


func _handle_key(event: InputEventKey) -> void:
	match event.keycode:
		KEY_SPACE:
			if not _simulator.is_running():
				_on_start_battle()
		KEY_ESCAPE:
			_clear_selection()
		KEY_R:
			_on_retreat()
		_:
			return


func _zoom_by(factor: float) -> void:
	var next := clampf(_camera.zoom.x * factor, 3.0, 26.0)
	_camera.zoom = Vector2(next, next)


## ---------- selection ----------------------------------------------------
## Click selects one unit; drag selects a box; shift adds to the selection. A
## click on empty ground clears the selection, so drag is never the only way.

func _begin_box_select() -> void:
	_box_selecting = true
	_box_start_world = _view.get_global_mouse_position()
	_box_current_world = _box_start_world


func _finish_box_select(additive: bool) -> void:
	if not _box_selecting:
		return
	_box_selecting = false
	_view.box_select_active = false

	var dragged_world := _box_start_world.distance_to(_box_current_world)
	var threshold_world := _drag_threshold_px / maxf(0.2, _camera.zoom.x)
	var found: Array[int] = []

	if dragged_world <= threshold_world:
		var unit_id := _view.unit_at(_box_start_world)
		if unit_id < 0:
			if not additive:
				_clear_selection()
			return
		found.append(unit_id)
	else:
		found = _view.units_in_rect(_world_rect(_box_start_world, _box_current_world))

	if additive:
		for unit_id in found:
			if not _view.selected_ids.has(unit_id):
				_view.selected_ids.append(unit_id)
	else:
		_view.selected_ids = found

	DebugLogger.debug("selected %d unit(s)" % _view.selected_ids.size(), "Battle")
	_view.queue_redraw()


func _clear_selection() -> void:
	_view.selected_ids.clear()
	_view.queue_redraw()


## Right-click on an enemy orders an attack; right-click on open ground orders a
## move. Orders issued before the battle starts are held until it does, so a plan
## can be set up first.
func _issue_move_order(world_point: Vector2) -> void:
	if _view.selected_ids.is_empty():
		_hint.text = "Select a unit first (click it, shift-click to add, or drag a box)."
		return
	var target_id := _view.unit_at(world_point)
	var target_unit := _simulator.find_unit(target_id) if target_id >= 0 else null
	var is_enemy := target_unit != null and target_unit.side != BattleContext.SIDE_PLAYER

	var issued := 0
	for unit_id in _view.selected_ids:
		var unit := _simulator.find_unit(unit_id)
		if unit == null or not unit.is_alive():
			continue
		if is_enemy:
			unit.attack_order_target_id = target_id
			unit.has_move_order = false
		else:
			unit.attack_order_target_id = -1
			unit.move_order = world_point
			unit.has_move_order = true
		issued += 1

	if issued <= 0:
		return
	if is_enemy:
		_hint.text = "%d unit(s) ordered to attack %s." % [issued, target_unit.display_name]
	else:
		_hint.text = "%d unit(s) ordered to %.0f, %.0f. Right-click an enemy to attack it instead." % [
			issued, world_point.x, world_point.y,
		]
	_view.queue_redraw()


func _world_rect(a: Vector2, b: Vector2) -> Rect2:
	var top_left := Vector2(minf(a.x, b.x), minf(a.y, b.y))
	return Rect2(top_left, Vector2(absf(b.x - a.x), absf(b.y - a.y)))


## ---------- actions ------------------------------------------------------

func _on_start_battle() -> void:
	if _simulator == null or _simulator.is_running():
		return
	_simulator.start()
	DebugLogger.info("battle started", "Battle")
	_hint.text = "The lines have engaged. Left-click to select, right-click an enemy to attack it, right-click ground to move. Space starts, R retreats."
	_refresh()


func _on_retreat() -> void:
	_resolve_and_show(true)


func _on_debug_exit() -> void:
	# Deliberately does NOT resolve: this path exists so a developer can leave an
	# inspection run without moving the campaign on.
	DebugLogger.info("debug exit from the battlefield - no consequences applied", "Battle")
	SceneManager.change_scene("world_map", {"select_settlement_id": ""})


## Decide the outcome, write it back to the campaign, and show the results.
## Guarded so a battle can only be resolved once, however it ended.
func _resolve_and_show(retreated: bool) -> void:
	if _resolved:
		return
	_resolved = true
	if _simulator.is_running() and not retreated:
		_simulator.state = BattleSimulator.State.FINISHED

	var state := GameManager.campaign
	var resolver := BattleResolver.build(state, _config)
	var result: BattleResult = null
	if resolver != null:
		result = resolver.build_result(_context, _simulator, _simulator.winner, _simulator.elapsed, retreated)
		resolver.apply(result, _context)
	else:
		result = BattleResult.new()
		result.battle_id = _context.battle_id
		result.enemy_display_name = _context.enemy_display_name

	DebugLogger.info("battle resolved: %s (%s)" % [result.title(), result.battle_id], "Battle")
	SceneManager.change_scene("battle_results", {"result": result, "context": _context})
