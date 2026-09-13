extends Node2D
## World map controller: input, camera, time advance, travel and HUD wiring.
##
## Thin by design. The view draws, the HUD reports and emits intent, the
## TravelService decides whether movement is legal, and the CampaignClock owns
## time. This script only connects them.

const SETTLEMENT_SCENE_KEY := "settlement"

@onready var _view: WorldMapView = $View
@onready var _camera: Camera2D = $Camera2D
@onready var _hud: WorldHud = $HUD

var _state: CampaignState = null
var _config: GameConfig = null
var _travel: TravelService = null
var _debug: DebugPanel = null

var _panning := false
var _hud_timer := 0.0
var _debug_timer := 0.0


func _ready() -> void:
	DebugLogger.info("world map loading", "WorldMap")

	if not GameManager.is_campaign_active():
		DebugLogger.warn("world map opened with no campaign; returning to the menu", "WorldMap")
		SceneManager.change_scene("main_menu")
		return

	_state = GameManager.campaign
	_config = GameManager.config()

	# A fresh campaign has no world yet; a loaded save already does.
	var builder := WorldBuilder.new(_state, _config)
	builder.build_if_needed()

	_travel = TravelService.new(_state, _config)
	_view.bind(_state, _config, _travel)

	_hud.setup(_state, _config, _travel)
	_hud.speed_requested.connect(_on_speed_requested)
	_hud.travel_requested.connect(_on_travel_requested)
	_hud.enter_settlement_requested.connect(_on_enter_settlement)
	_hud.save_requested.connect(_on_save_requested)
	_hud.menu_requested.connect(_on_menu_requested)

	_debug = DebugPanel.new()
	_hud.add_child(_debug)
	_debug.setup(_state, _config, _travel)
	_debug.teleport_requested.connect(_on_teleport_requested)
	_debug.gold_requested.connect(_on_gold_requested)
	_debug.speed_requested.connect(_on_speed_requested)
	_debug.state_requested.connect(_refresh)

	_focus_camera_on_party()
	_restore_selection_from_payload()
	_refresh()
	_hud.set_hint("Click a settlement to inspect it. Click Travel Here to set out. F1 opens debug tools.")

	_apply_dev_autotravel()


## Dev-only: begin travelling immediately (see DevFlags). Used by automated runs
## to exercise the real rendered world map without a mouse.
func _apply_dev_autotravel() -> void:
	var town := DevFlags.autostart_town()
	if not town.is_empty():
		DebugLogger.info("dev flag: entering %s directly" % town, "WorldMap")
		_travel.teleport_to(town)
		_on_enter_settlement(town)
		return
	var destination := DevFlags.autotravel_destination()
	if destination.is_empty():
		return
	var settlement := _state.settlement(destination)
	if settlement == null:
		DebugLogger.warn("dev flag: unknown autotravel destination '%s'" % destination, "WorldMap")
		return
	DebugLogger.info("dev flag: autotravelling to %s" % settlement.name, "WorldMap")
	_on_travel_requested(destination)


## ---------- per-frame ----------------------------------------------------

func _process(delta: float) -> void:
	if _state == null:
		return

	_update_camera_pan(delta)

	var game_hours := _state.clock.advance_real_seconds(delta)
	if game_hours > 0.0:
		var report := _travel.step(game_hours)
		if report.get("arrived", false):
			_on_arrived(str(report.get("settlement_id", "")))

	_view.queue_redraw()

	# HUD text does not need to run at frame rate.
	_hud_timer += delta
	if _hud_timer >= 0.1:
		_hud_timer = 0.0
		_refresh()


func _refresh() -> void:
	_hud.refresh()
	if _debug != null:
		_debug.refresh()


func _on_arrived(settlement_id: String) -> void:
	var settlement := _state.settlement(settlement_id)
	if settlement == null:
		return
	_hud.set_hint("Arrived at %s on %s." % [settlement.name, _state.clock.full_string()])
	_select(settlement)
	_refresh()


## ---------- camera -------------------------------------------------------

func _focus_camera_on_party() -> void:
	_camera.position = _state.world_position
	_camera.zoom = Vector2.ONE


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
	var size := _view.map_size()
	var margin := 200.0
	_camera.position = Vector2(
		clampf(_camera.position.x, -margin, size.x + margin),
		clampf(_camera.position.y, -margin, size.y + margin)
	)


func _zoom_by(factor: float) -> void:
	var min_zoom := _config.get_float("world.camera_min_zoom", 0.45)
	var max_zoom := _config.get_float("world.camera_max_zoom", 2.2)
	var next := clampf(_camera.zoom.x * factor, min_zoom, max_zoom)
	_camera.zoom = Vector2(next, next)


## ---------- input --------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if _state == null:
		return

	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_by(1.12)
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_by(1.0 / 1.12)
		elif button.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = button.pressed
		elif button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
			_handle_left_click(_view.get_global_mouse_position())
		return

	if event is InputEventMouseMotion and _panning:
		var motion := event as InputEventMouseMotion
		_camera.position -= motion.relative / _camera.zoom
		_clamp_camera()
		return

	if event is InputEventKey and event.pressed and not event.echo:
		_handle_key(event as InputEventKey)


func _handle_left_click(world_point: Vector2) -> void:
	var settlement := _view.settlement_at(world_point)
	if settlement == null:
		_deselect()
		return
	_select(settlement)


func _handle_key(event: InputEventKey) -> void:
	match event.keycode:
		KEY_F1:
			if _debug != null:
				_debug.toggle()
		KEY_SPACE:
			_state.clock.toggle_pause()
			_hud.set_hint("Time %s." % _state.clock.speed_name().to_lower())
		KEY_1:
			_on_speed_requested("paused")
		KEY_2:
			_on_speed_requested("normal")
		KEY_3:
			_on_speed_requested("fast")
		KEY_ESCAPE:
			_deselect()
		KEY_F5:
			_on_save_requested()
		KEY_R:
			_travel.clear_destination()
			_hud.set_hint("Travel cancelled.")
		_:
			return
	_refresh()


## ---------- selection ----------------------------------------------------

func _select(settlement: Settlement) -> void:
	_view.selected_id = settlement.id
	_view.queue_redraw()
	_hud.show_settlement(settlement)


func _deselect() -> void:
	_view.selected_id = ""
	_view.queue_redraw()
	_hud.hide_settlement()


func _restore_selection_from_payload() -> void:
	var payload := SceneManager.consume_payload()
	var wanted := str(payload.get("select_settlement_id", ""))
	if wanted.is_empty():
		return
	var settlement := _state.settlement(wanted)
	if settlement != null:
		_select(settlement)


## ---------- HUD actions --------------------------------------------------

func _on_speed_requested(speed_name: String) -> void:
	if not _state.clock.set_speed_by_name(speed_name):
		return
	_refresh()


func _on_travel_requested(settlement_id: String) -> void:
	var settlement := _state.settlement(settlement_id)
	if settlement == null:
		return
	if _travel.set_destination(settlement_id):
		var hours := _travel.hours_to_reach(settlement.position)
		_hud.set_hint("Travelling to %s - %.0f units, about %.1f game hours at %s speed." % [
			settlement.name,
			_travel.distance_to(settlement.position),
			hours,
			_state.clock.speed_name().to_lower(),
		])
	else:
		_hud.set_hint("%s is right here. Choose Enter %s instead." % [settlement.name, settlement.name])
	_refresh()


func _on_enter_settlement(settlement_id: String) -> void:
	var settlement := _state.settlement(settlement_id)
	if settlement == null:
		return
	if not _travel.is_at_settlement(settlement_id):
		_hud.set_hint("Travel to %s first." % settlement.name)
		return
	DebugLogger.info("entering %s" % settlement.name, "WorldMap")
	SceneManager.change_scene(SETTLEMENT_SCENE_KEY, {"settlement_id": settlement_id})


func _on_save_requested() -> void:
	if GameManager.save_campaign():
		_hud.set_hint("Campaign saved.")
	else:
		_hud.set_hint("Save failed - see the log.")


func _on_menu_requested() -> void:
	GameManager.save_campaign()
	SceneManager.change_scene("main_menu")


func _on_teleport_requested(settlement_id: String) -> void:
	if _travel.teleport_to(settlement_id):
		var settlement := _state.settlement(settlement_id)
		_focus_camera_on_party()
		_select(settlement)
		_refresh()


func _on_gold_requested(amount: int) -> void:
	_state.player_gold += amount
	DebugLogger.info("debug: gold %+d -> %d" % [amount, _state.player_gold], "Debug")
	_refresh()
