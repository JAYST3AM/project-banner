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
## Frames in, whole simulation ticks out. See [BattleClock] and D-103.
var _clock: BattleClock = null
## Dev-only: the transitions of a long battle, written down. Null unless the run asked for a
## journal with --battlelog. See [BattleJournal].
var _journal: BattleJournal = null
## The enemy's commander. Formation-level thinking, kept out of the simulator.
var _ai: BattleAI = null
var _formations_built := 0
## Counter for formations the player detaches, so their ids stay readable and unique.
var _formation_counter := 0
## Scripted formation drill for automated runs (DevFlags.autoformations()).
var _drill_enabled := false
var _drill_step := 0


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
	# The clock is built from the game data before the battle starts, so the step the fight
	# will be simulated at is a design decision read from a file rather than whatever the
	# first frame happens to take. See [BattleClock].
	_clock = BattleClock.create(_config)
	_simulator.add_units(units)
	# The ground comes from the context's terrain seed, so the same battle is fought on
	# the same field every time it is replayed. It is built before the armies are formed
	# because where the armies end up standing is a question about the ground.
	_simulator.set_terrain_from_context(_context, _config)
	var formations := BattleSetup.assign_default_formations(_simulator, _config)
	_ai = BattleAI.create(_config)
	_view.bind(_simulator, _context)
	_formations_built = formations.size()

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
	_drill_enabled = DevFlags.autoformations()
	if _drill_enabled:
		DebugLogger.info("dev flag: a scripted formation drill will run during this battle", "Battle")
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

	# Formation commands. Development-grade controls, but real orders: each one is
	# something a commander would actually say, and each one is executed by soldiers
	# walking rather than by the shape changing under them.
	var formation_panel := PanelContainer.new()
	formation_panel.add_theme_stylebox_override("panel", UiTheme.panel_style())
	formation_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	formation_panel.position = Vector2(12.0, -104.0)
	hud.add_child(formation_panel)
	var formation_box := HBoxContainer.new()
	formation_box.add_theme_constant_override("separation", 6)
	formation_panel.add_child(formation_box)

	formation_box.add_child(UiTheme.label("Selected:", 13, UiTheme.DIM))
	var line_button := UiTheme.button("Line (1)", 84.0)
	line_button.pressed.connect(_order_formation_type.bind("line"))
	formation_box.add_child(line_button)
	var column_button := UiTheme.button("Column (2)", 96.0)
	column_button.pressed.connect(_order_formation_type.bind("column"))
	formation_box.add_child(column_button)
	var loose_button := UiTheme.button("Loose (3)", 88.0)
	loose_button.pressed.connect(_order_formation_type.bind("loose"))
	formation_box.add_child(loose_button)
	var turn_left := UiTheme.button("Turn L (Q)", 92.0)
	turn_left.pressed.connect(_turn_selection.bind(-PI * 0.25))
	formation_box.add_child(turn_left)
	var turn_right := UiTheme.button("Turn R (E)", 92.0)
	turn_right.pressed.connect(_turn_selection.bind(PI * 0.25))
	formation_box.add_child(turn_right)
	var hold_button := UiTheme.button("Hold (H)", 84.0)
	hold_button.tooltip_text = "Stand fast: soldiers hold their places instead of closing."
	hold_button.pressed.connect(_order_stance.bind(BattleFormation.ORDER_HOLD))
	formation_box.add_child(hold_button)
	var engage_button := UiTheme.button("Engage (G)", 102.0)
	engage_button.tooltip_text = "Close with the enemy and keep closing."
	engage_button.pressed.connect(_order_stance.bind(BattleFormation.ORDER_ENGAGE))
	formation_box.add_child(engage_button)
	var overlay_button := UiTheme.button("Overlay (F3)", 110.0)
	overlay_button.tooltip_text = "Show anchors, facing, target slots and cohesion."
	overlay_button.pressed.connect(_toggle_overlay)
	formation_box.add_child(overlay_button)

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
		_terrain_line(),
		"Time:         Day %d %s   (elapsed %d:%02d)" % [
			_context.campaign_day,
			CampaignClock.time_string_from_hour(_context.campaign_hour),
			int(_simulator.elapsed) / 60,
			int(_simulator.elapsed) % 60,
		],
		"Battle state: %s" % _state_name(),
		"",
		_formation_summary(),
	])
	_start_button.disabled = _simulator.is_running()
	var selected := _view.selected_ids.size()
	_retreat_button.text = "Retreat" if selected == 0 else "Retreat (%d selected)" % selected


## What the field is made of. Worth showing: the ground is now a fact about the battle
## rather than decoration, and a player who cannot see it cannot plan around it.
func _terrain_line() -> String:
	if _simulator == null or _simulator.terrain == null:
		return "Terrain:      featureless"
	var counts := _simulator.terrain.counts_by_type()
	var parts: Array[String] = []
	for id in counts.keys():
		parts.append("%s %d" % [str(id), int(counts[id])])
	if parts.is_empty():
		return "Terrain:      featureless"
	return "Terrain:      %s cells" % ", ".join(parts)


## One line per player body. Cohesion is the number worth watching: it is the honest
## answer to the only question that matters about a formation, which is whether it is
## still one.
func _formation_summary() -> String:
	if _simulator == null:
		return ""
	var lines: Array[String] = []
	for formation in _simulator.formations:
		if formation.side != BattleContext.SIDE_PLAYER:
			continue
		if not formation.has_living_units(_simulator.units_by_id()):
			continue
		lines.append("  %-15s %-7s %2dx%-2d  %3.0f%%  %s" % [
			formation.id, formation.display_name(), formation.file_count, formation.rank_count,
			formation.cohesion * 100.0, formation.state_name()])
	if lines.is_empty():
		return "Formations:   none - soldiers are acting on their own"
	return "Formations (%d):\n%s" % [lines.size(), "\n".join(lines)]


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
		# The enemy's thinking happens here, above the soldiers and outside the
		# simulator: the battlefield does not decide anything on its own, so a battle
		# with no commander attached is a battle where nothing moves that was not
		# ordered to.
		#
		# [b]The frame's own length stops here.[/b] Real seconds go into the clock and whole
		# ticks of one fixed size come out, so a frame that took twice as long runs twice as
		# many ticks instead of one tick twice the size. That is the difference between a slow
		# machine and a different battle, and before this it was neither - it was the same
		# seed producing a different fight. See [BattleClock] and D-103.
		var ticks := _clock.frame(delta, _battle_speed)
		for i in ticks:
			if not _simulator.is_running():
				break
			_ai.update(_simulator, _clock.step)
			var events := _simulator.step(_clock.step)
			_view.add_events(events)
			if _journal != null:
				_journal.observe(_simulator)
		_update_formation_drill()
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
		# Formation orders. Development-grade keys, but the commands themselves are the
		# real ones: each of these is an order a commander would give, not a debug knob.
		KEY_1:
			_order_formation_type("line")
		KEY_2:
			_order_formation_type("column")
		KEY_3:
			_order_formation_type("loose")
		KEY_Q:
			_turn_selection(-PI * 0.25)
		KEY_E:
			_turn_selection(PI * 0.25)
		KEY_H:
			_order_stance(BattleFormation.ORDER_HOLD)
		KEY_G:
			_order_stance(BattleFormation.ORDER_ENGAGE)
		KEY_F3:
			_toggle_overlay()
		KEY_F4:
			_view.show_terrain = not _view.show_terrain
			_hint.text = "Ground rendering %s." % ("on" if _view.show_terrain else "off")
			_view.queue_redraw()
		_:
			return


## ---------- formation orders ---------------------------------------------

## Every selected soldier still on their feet.
func _living_selection() -> Array[int]:
	var out: Array[int] = []
	for unit_id in _view.selected_ids:
		var unit := _simulator.find_unit(unit_id)
		if unit != null and unit.is_alive():
			out.append(unit_id)
	return out


## The body the selection is being treated as.
##
## The rule is deliberately simple: everything selected acts as one formation. If the
## selection is exactly an existing body, that body is reused so repeated orders do not
## spawn a new one each time. Otherwise the selected soldiers are gathered into a fresh
## body and taken out of whatever held them - which is how a commander detaches a group
## from the line, and it is why the line it came from now has a gap in it.
func _formation_for_selection() -> BattleFormation:
	var ids := _living_selection()
	if ids.is_empty():
		return null

	for formation in _simulator.formations:
		if formation.side != BattleContext.SIDE_PLAYER or formation.unit_ids.size() != ids.size():
			continue
		var matches := true
		for unit_id in ids:
			if not formation.has_unit(unit_id):
				matches = false
				break
		if matches:
			return formation

	_formation_counter += 1
	var formation := BattleFormation.create(
		"player_body_%d" % _formation_counter,
		BattleContext.SIDE_PLAYER,
		_centroid_of(ids),
		_facing_toward_enemy(),
		"line",
		FormationCatalog.load_from(),
		_config
	)
	formation.order_hold()
	_simulator.add_formation(formation)
	_simulator.assign_formation(formation, ids)
	return formation


func _centroid_of(unit_ids: Array[int]) -> Vector2:
	var total := Vector2.ZERO
	var counted := 0
	for unit_id in unit_ids:
		var unit := _simulator.find_unit(unit_id)
		if unit == null:
			continue
		total += unit.position
		counted += 1
	if counted == 0:
		return Vector2.ZERO
	return total / float(counted)


## Which way a freshly detached body should face: at the enemy, since that is what a
## soldier who has just been told to form up is about to be doing.
func _facing_toward_enemy() -> float:
	var mine := _simulator.side_count(BattleContext.SIDE_PLAYER)
	var theirs := _simulator.side_count(BattleContext.SIDE_ENEMY)
	if mine == 0 or theirs == 0:
		return 0.0
	var our_centre := Vector2.ZERO
	var their_centre := Vector2.ZERO
	var ours := 0
	var theirs_counted := 0
	for unit in _simulator.units:
		if not unit.is_alive():
			continue
		if unit.side == BattleContext.SIDE_PLAYER:
			our_centre += unit.position
			ours += 1
		else:
			their_centre += unit.position
			theirs_counted += 1
	if ours == 0 or theirs_counted == 0:
		return 0.0
	var to_enemy := (their_centre / float(theirs_counted)) - (our_centre / float(ours))
	if to_enemy.length() < 0.001:
		return 0.0
	return to_enemy.angle()


## Order every body that has a selected soldier in it. A body is the unit of command;
## a soldier standing in one is not given its own destination.
func _selected_formations() -> Array[BattleFormation]:
	var out: Array[BattleFormation] = []
	var selected := {}
	for unit_id in _living_selection():
		selected[unit_id] = true
	for formation in _simulator.formations:
		if formation.side != BattleContext.SIDE_PLAYER:
			continue
		for unit_id in formation.unit_ids:
			if selected.has(unit_id):
				out.append(formation)
				break
	return out


func _order_formation_type(type_id: String) -> void:
	if _living_selection().is_empty():
		_hint.text = "Select soldiers first (click, shift-click or drag), then choose a formation."
		return
	var formation := _formation_for_selection()
	if formation == null:
		return
	formation.set_type(type_id)
	if formation.is_empty():
		return
	_hint.text = "%s ordered into %s: %d files by %d ranks%s." % [
		formation.id, formation.display_name(), formation.file_count, formation.rank_count,
		" - they will walk into it" if _simulator.is_running() else "",
	]
	_view.queue_redraw()


func _turn_selection(radians: float) -> void:
	var formations := _selected_formations()
	if formations.is_empty():
		_hint.text = "Select soldiers in a formation first, then Q or E to turn them."
		return
	for formation in formations:
		formation.order_face(formation.desired_facing + radians)
	_hint.text = "%d formation(s) turning to %.0f degrees." % [formations.size(), rad_to_deg(formations[0].desired_facing)]


func _order_stance(order: String) -> void:
	var formations := _selected_formations()
	if formations.is_empty():
		_hint.text = "Select soldiers in a formation first."
		return
	for formation in formations:
		if order == BattleFormation.ORDER_HOLD:
			formation.order_hold()
		else:
			formation.order_engage()
	_hint.text = "%d formation(s) told to %s." % [
		formations.size(), "hold the line" if order == BattleFormation.ORDER_HOLD else "close with the enemy"]


func _toggle_overlay() -> void:
	_view.show_formation_debug = not _view.show_formation_debug
	_hint.text = "Formation overlay %s (anchors, facing, target slots, cohesion)." % (
		"on" if _view.show_formation_debug else "off")
	_view.queue_redraw()


## ---------- scripted formation drill (development only) ------------------

## A timed sequence of the commands a player would give, run against the real order
## methods rather than a parallel test path. Enabled with `--autoformations`; the
## windowed smoke run uses it so that the controls a headless suite can only reason
## about are actually executed through the scene once.
const DRILL := [
	{"at": 0.0, "do": "select_all"},
	{"at": 0.2, "do": "line"},
	{"at": 1.0, "do": "select_three"},
	{"at": 1.2, "do": "column"},
	{"at": 1.4, "do": "move_detached"},
	{"at": 2.2, "do": "select_all"},
	{"at": 2.4, "do": "loose"},
	{"at": 3.0, "do": "turn_left"},
	{"at": 3.6, "do": "turn_right"},
	{"at": 4.2, "do": "overlay_on"},
	{"at": 4.6, "do": "select_all"},
	{"at": 4.8, "do": "line"},
	{"at": 5.2, "do": "report"},
	{"at": 5.6, "do": "overlay_off"},
]


## Run any drill steps that have come due. Called once per frame while the battle runs.
func _update_formation_drill() -> void:
	if not _drill_enabled or _simulator == null:
		return
	var elapsed := _simulator.elapsed
	while _drill_step < DRILL.size() and elapsed >= float(DRILL[_drill_step]["at"]):
		_drill_apply(str(DRILL[_drill_step]["do"]))
		_drill_step += 1


func _drill_apply(action: String) -> void:
	match action:
		"select_all":
			_view.selected_ids = _living_player_ids()
			DebugLogger.info("drill select_all: %d soldiers selected" % _view.selected_ids.size(), "Battle")
		"select_three":
			_view.selected_ids = _living_player_ids().slice(0, 3)
			DebugLogger.info("drill select_three: %d soldiers selected" % _view.selected_ids.size(), "Battle")
		"line":
			_drill_order("line")
		"column":
			_drill_order("column")
		"loose":
			_drill_order("loose")
		"turn_left":
			_turn_selection(-PI * 0.25)
			DebugLogger.info("drill turn_left: %s" % _hint.text, "Battle")
		"turn_right":
			_turn_selection(PI * 0.25)
			DebugLogger.info("drill turn_right: %s" % _hint.text, "Battle")
		"move_detached":
			var point := Vector2(_simulator.field_size.x * 0.35, _simulator.field_size.y * 0.5)
			_move_selection_to(point)
			DebugLogger.info("drill move_detached: %s" % _hint.text, "Battle")
		"overlay_on":
			_view.show_formation_debug = true
			_view.queue_redraw()
			DebugLogger.info("drill overlay_on", "Battle")
		"overlay_off":
			_view.show_formation_debug = false
			_view.queue_redraw()
			DebugLogger.info("drill overlay_off", "Battle")
		"report":
			_report_formation_consistency()
		_:
			DebugLogger.error("drill: unknown action '%s'" % action, "Battle")
	_view.queue_redraw()


func _drill_order(type_id: String) -> void:
	_order_formation_type(type_id)
	DebugLogger.info("drill %s: %s" % [type_id, _hint.text], "Battle")


func _living_player_ids() -> Array[int]:
	var ids: Array[int] = []
	for unit in _simulator.units:
		if unit.side == BattleContext.SIDE_PLAYER and unit.is_alive():
			ids.append(unit.id)
	return ids


## A blunt internal consistency check, logged rather than asserted: every player body's
## geometry must describe the soldiers it actually holds. This is the thing a stale
## formation looks like from the outside, and it is checked here in a running battle
## rather than only in a unit test.
func _report_formation_consistency() -> void:
	var problems := 0
	for formation in _simulator.formations:
		var men := formation.unit_ids.size()
		var places := formation.slots.size()
		var mismatched := 0
		for i in men:
			var unit := _simulator.find_unit(formation.unit_ids[i])
			if unit == null or unit.formation_ref != formation or unit.slot_index != i:
				mismatched += 1
		if men != places or mismatched > 0:
			problems += 1
			DebugLogger.error("formation %s inconsistent: %d men, %d places, %d soldiers misassigned" % [
				formation.id, men, places, mismatched], "Battle")
	DebugLogger.info("drill report: %d player bodies, %d inconsistencies%s" % [
		_simulator.formations_of(BattleContext.SIDE_PLAYER).size(), problems,
		"" if problems == 0 else " - SEE ERRORS ABOVE"], "Battle")


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


## Right-click on an enemy orders an attack; right-click on open ground orders a move.
## Orders issued before the battle starts are held until it does, so a plan can be set
## up first.
##
## Move orders go to [b]formations[/b], not to individual soldiers. A soldier standing
## in a body is not given its own destination: the body is told where to go, and its
## soldiers are told where their places are. That is the whole architectural change
## this milestone exists to make, and it is visible here first.
func _issue_move_order(world_point: Vector2) -> void:
	if _view.selected_ids.is_empty():
		_hint.text = "Select a unit first (click it, shift-click to add, or drag a box)."
		return
	var target_id := _view.unit_at(world_point)
	var target_unit := _simulator.find_unit(target_id) if target_id >= 0 else null
	var is_enemy := target_unit != null and target_unit.side != BattleContext.SIDE_PLAYER

	if is_enemy:
		# Attack orders stay per-soldier. Telling one man to go for a particular enemy
		# is a thing a commander does, and it does not change the shape of the line.
		var issued := 0
		for unit_id in _view.selected_ids:
			var unit := _simulator.find_unit(unit_id)
			if unit == null or not unit.is_alive():
				continue
			unit.attack_order_target_id = target_id
			unit.has_move_order = false
			issued += 1
		if issued <= 0:
			return
		_hint.text = "%d unit(s) ordered to attack %s." % [issued, target_unit.display_name]
		_view.queue_redraw()
		return

	_move_selection_to(world_point)


## Send the selection somewhere, as bodies.
##
## Two cases, and the difference is worth stating because it is the whole command
## model: selecting whole formations moves those formations, while selecting part of
## one detaches those soldiers into a body of their own and sends that. Either way what
## arrives on the far side is a formation, not a straggle.
func _move_selection_to(world_point: Vector2) -> void:
	if _selection_is_whole_bodies():
		var formations := _selected_formations()
		for formation in formations:
			formation.order_move_to(world_point)
		_hint.text = "%d formation(s) ordered to %.0f, %.0f." % [
			formations.size(), world_point.x, world_point.y]
		_view.queue_redraw()
		return

	var formation := _formation_for_selection()
	if formation == null:
		return
	formation.order_move_to(world_point)
	_hint.text = "%d soldiers detached as %s and ordered to %.0f, %.0f." % [
		formation.unit_ids.size(), formation.id, world_point.x, world_point.y]
	_view.queue_redraw()


## Whether the selection is exactly one or more entire formations. If it is, a move
## order moves them; if it is not, it is a detachment and has to be formed up first.
func _selection_is_whole_bodies() -> bool:
	var ids := _living_selection()
	if ids.is_empty():
		return false
	var selected := {}
	for unit_id in ids:
		selected[unit_id] = true
	for unit_id in ids:
		var unit := _simulator.find_unit(unit_id)
		if unit == null or unit.formation_ref == null:
			return false
		for brother_id in unit.formation_ref.unit_ids:
			var brother := _simulator.find_unit(brother_id)
			if brother != null and brother.is_alive() and not selected.has(brother_id):
				return false
	return true


func _world_rect(a: Vector2, b: Vector2) -> Rect2:
	var top_left := Vector2(minf(a.x, b.x), minf(a.y, b.y))
	return Rect2(top_left, Vector2(absf(b.x - a.x), absf(b.y - a.y)))


## ---------- actions ------------------------------------------------------

func _on_start_battle() -> void:
	if _simulator == null or _simulator.is_running():
		return
	_simulator.start()
	# A battle starts with an empty accumulator: time spent on the deployment screen is not
	# simulation time waiting to be caught up. See [BattleClock].
	_clock.reset()
	DebugLogger.info("battle started at a fixed %.1f ticks/second" % _clock.rate(), "Battle")
	_hint.text = "Select soldiers, then 1/2/3 for line, column or loose, Q/E to turn, H to hold, G to engage, right-click to move them as a body. F3 shows the formation overlay. Space starts, R retreats."
	# Dev-only, and off unless the run asked for it: the transitions a long battle turns on.
	if _journal == null and DevFlags.battle_log_requested():
		_journal = BattleJournal.open(DevFlags.battle_log_path())
		if _journal != null:
			_journal.note_start(_simulator, _context.battle_seed)
			DebugLogger.info("battle journal: %s" % _journal.path, "Battle")
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
	# The journal has said everything it is going to say about this battle.
	if _journal != null:
		_journal.close()
	SceneManager.change_scene("battle_results", {"result": result, "context": _context})
