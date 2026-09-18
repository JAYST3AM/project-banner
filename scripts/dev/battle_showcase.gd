extends Node2D
## Development-only 300 vs 300 battle showcase.
##
## [b]What this is for.[/b] Before optimising the separation pass, the production build
## needs a battle large enough to be a battle and small enough to watch. This scene builds
## one - three bodies a side of about a hundred soldiers each, six hundred persistent
## [BattleUnit]s in total - out of the real production pieces: the same
## [BattleSimulator], the same formations, the same targeting, the same damage rules, the
## same terrain. Nothing here weakens a system to make the picture tidier.
##
## [b]What it is not.[/b] It is not part of the game. It is not a cinematic: there are no
## scripted deaths, no staged charges and no set pieces. It builds a battle, drives both
## armies with the production formation AI (a showcase with nobody at the keyboard needs
## both sides to be given orders), runs it at a fixed number of simulation ticks per
## rendered frame, and watches.
##
## [b]Why the overlay is on screen and why it is not a profiler.[/b] The point of running
## this windowed is to see - and to write down - what a real-scale battle costs while it is
## happening. The overlay reads render FPS, frame time, simulation ms per tick and the
## simulation's own tick rate separately on purpose: they are different quantities and a
## table that calls one of them the other is not a measurement. It is a label, redrawn a
## few times a second, and [code]--overlay=0[/code] turns it off so its own cost can be
## compared against a run without it.
##
## Usage:
## [codeblock]
## godotc --path "<project>" res://scenes/dev/battle_showcase.tscn -- \
##     --per-side=300 --ticks-per-frame=2 --out="F:/VSC Projects/pb-bench/showcase"
## [/codeblock]
## Switches: [code]--per-side=[/code], [code]--ticks-per-frame=[/code],
## [code]--out=[/code], [code]--seed=[/code], [code]--shots=[/code],
## [code]--overlay=[/code], [code]--units=[/code] (archetype),
## [code]--enemy-units=[/code], [code]--max-ticks=[/code], [code]--probe-every=[/code],
## [code]--no-terrain[/code] (the baseline half of a terrain benchmark).

const TICK := 0.05
const FIELD := Vector2(200.0, 120.0)
const WINDOW_SIZE := Vector2i(1600, 900)
const SIDE_PLAYER := BattleContext.SIDE_PLAYER
const SIDE_ENEMY := BattleContext.SIDE_ENEMY

## How many soldiers each body holds. Three bodies a side at this size is three hundred.
const BODY_SIZE := 100
const BODY_IDS := ["centre", "left", "right"]

enum Stage { OPENING, APPROACH, CONTACT, MELEE, ATTRITION, RESULT, DONE }

var _per_side := 300
var _ticks_per_frame := 2
var _max_ticks := 100000
var _seed := 780780
var _shots := true
var _overlay_enabled := true
var _probe_every := 10
var _out_dir := "F:/VSC Projects/pb-bench/showcase_300v300"
## Whether the battle is fought on generated ground. Off is the before-half of a before-and-after
## benchmark: [code]--no-terrain[/code] runs the same armies on the same field with no terrain at all.
var _terrain_enabled := true
var _unit_type := "spearman"
var _enemy_unit_type := "spearman"
## The battle's own clock limit. Left at zero the production value is used - six hundred
## seconds, which on a field this size is a cap a 300 v 300 fight reaches before it decides
## anything. Raising it is not a change to a combat rule: it lets the same fight run long
## enough to produce a winner, and the report says which limit was in force.
var _max_seconds := 0.0
## Dev-only battle journal: "" unless the run asked for one with --battlelog[=<path>].
var _journal_path := ""
var journal: BattleJournal = null

var config: GameConfig = null
var catalog: FormationCatalog = null
var units_catalog: UnitCatalog = null
var context: BattleContext = null
var simulator: BattleSimulator = null
var terrain: BattlefieldTerrain = null
var view: BattleView = null
## The army's renderer: the same instanced path the battle scene uses, so what is watched here
## is what a player sees. Null only if the instance-buffer layout could not be read back.
var field: SoldierField = null
var camera: Camera2D = null
## Whether the player has taken the camera. The film follows the battle stage by stage; the moment
## the player pans or zooms it stops, and F hands it back. Without this the showcase is something
## you watch rather than something you can look at.
var camera_manual: bool = false
## Middle mouse button held: dragging the view.
var _panning: bool = false
const CAMERA_PAN_SPEED := 700.0
const CAMERA_ZOOM_STEP := 1.12
var ai_player: BattleAI = null
var ai_enemy: BattleAI = null

var _started := false
var _stage := Stage.OPENING
var _stage_label := "opening"
var _stage_marks: Array[Dictionary] = []
var _shots_taken: Array[Dictionary] = []

## Simulation cost, one sample per tick. Development instrumentation for this scene only.
var _sim_usecs: PackedFloat32Array = PackedFloat32Array()
var _sim_total_usec: int = 0
var _frame_times: PackedFloat32Array = PackedFloat32Array()
var _frames_seen: int = 0
var _run_start_usec: int = 0
var _rolling_fps: Array[float] = []
var _fps_at_contact := 0.0
var _fps_at_melee := 0.0
var _ticks_this_frame := 0

## Physicality probe results: how deep soldiers actually get into each other while the
## pass is running, and the largest single-tick move anybody made.
var _probe_min_distance_sum := 0.0
var _probe_min_distance_worst := 999.0
var _probe_deep_pairs := 0
var _probe_count := 0
var _probe_checks := 0
var _launch_max := 0.0
var _last_positions: Dictionary = {}

## Overlay nodes.
var _hud: CanvasLayer = null
var _perf_label: Label = null
var _form_label: Label = null
var _overlay_timer := 0.0

var _events_seen := 0
var _hits := 0
var _deaths := 0
var _deaths_player := 0
var _deaths_enemy := 0
var _first_hit_tick := -1
var _first_contact_tick := -1
var _shot_pending := ""
var _shot_queued := ""
var _capture_busy := false
var _last_probe_tick := 0
var _grace_frames := 0
var _finished_tick := -1
var _last_heartbeat := -1


func _ready() -> void:
	_parse_args()
	# Uncapped and unsynchronised: a vsynced frame time is the monitor's, not the game's,
	# and this run exists to put a number on what the game costs to draw.
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DisplayServer.window_set_size(WINDOW_SIZE)
	get_window().size = WINDOW_SIZE
	DirAccess.make_dir_recursive_absolute(_out_dir)
	config = GameManager.config()
	catalog = FormationCatalog.load_from()
	units_catalog = UnitCatalog.load_from()
	_build_battle()
	print("showcase: %d v %d deployed, %d formations, field %.0fx%.0f, setup %s" % [
		simulator.side_count(SIDE_PLAYER), simulator.side_count(SIDE_ENEMY),
		simulator.formations.size(), simulator.field_size.x, simulator.field_size.y,
		ShowcaseBattle.setup_checksum(simulator.units)])
	_started = false
	_run_start_usec = Time.get_ticks_usec()


## ---------- setup ---------------------------------------------------------

func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--per-side="):
			_per_side = maxi(2, int(arg.substr(11)))
		elif arg.begins_with("--ticks-per-frame="):
			_ticks_per_frame = maxi(1, int(arg.substr(18)))
		elif arg.begins_with("--out="):
			_out_dir = arg.substr(6)
		elif arg.begins_with("--seed="):
			_seed = int(arg.substr(7))
		elif arg.begins_with("--shots="):
			_shots = arg.substr(8).to_int() != 0
		elif arg.begins_with("--overlay="):
			_overlay_enabled = arg.substr(10).to_int() != 0
		elif arg.begins_with("--probe-every="):
			_probe_every = maxi(0, int(arg.substr(14)))
		elif arg.begins_with("--max-ticks="):
			_max_ticks = maxi(1, int(arg.substr(12)))
		elif arg.begins_with("--units="):
			_unit_type = arg.substr(8)
		elif arg.begins_with("--enemy-units="):
			_enemy_unit_type = arg.substr(14)
		elif arg == "--no-terrain":
			_terrain_enabled = false
		elif arg.begins_with("--max-seconds="):
			_max_seconds = maxf(0.0, float(arg.substr(14)))
		elif arg == "--battlelog":
			_journal_path = BattleJournal.DEFAULT_PATH
		elif arg.begins_with("--battlelog="):
			_journal_path = arg.substr(12)


## Build the armies, the ground and the bodies. Everything goes through the production
## constructors the battle scene uses, and the deployment itself lives in [ShowcaseBattle]
## because the stalemate regression and the automated probe open this same battle - one
## definition, so the run that is watched and the run that is measured cannot drift apart.
func _build_battle() -> void:
	var built := ShowcaseBattle.build(
		config, units_catalog, catalog, _per_side, _seed,
		_unit_type, _enemy_unit_type, _max_seconds, _terrain_enabled)
	context = built["context"]
	simulator = built["simulator"]
	terrain = built["terrain"]

	view = BattleView.new()
	add_child(view)
	view.bind(simulator, context)
	# The development overlay: team colours are always on; bounds, slots, facing arrows and
	# cohesion labels are what this switch adds. The world-space text labels are dropped
	# because at a camera that shows two three-hundred-man armies the words cover the field -
	# the same information is in the corner panel in readable size.
	view.show_formation_debug = true
	view.show_formation_labels = false

	# The same instanced renderer the battle scene uses. Attached after the view, so the army
	# draws over the ground the view painted and under its selection rings and order lines.
	# `PB_RENDER_BACKEND=canvas` leaves the view drawing every soldier, which is how the two
	# paths are compared in one build.
	if OS.get_environment("PB_RENDER_BACKEND") == "canvas":
		print("showcase: canvas render path (PB_RENDER_BACKEND=canvas)")
	else:
		field = SoldierField.attach(self, view, simulator)
		if field != null and not field.has_usable_buffer():
			# No usable instance-buffer layout: the view keeps drawing the soldiers and this
			# scene keeps measuring something honest rather than men at the wrong coordinates.
			field.queue_free()
			field = null
		print("showcase: %s render path" % ("instanced" if field != null else "canvas (buffer unusable)"))

	camera = Camera2D.new()
	add_child(camera)
	camera.make_current()
	camera.position = simulator.field_size * 0.5
	camera.zoom = _fit_zoom()

	ai_player = BattleAI.create(config, SIDE_PLAYER)
	ai_enemy = BattleAI.create(config, SIDE_ENEMY)

	_build_hud()


## ---------- camera --------------------------------------------------------

func _fit_zoom() -> Vector2:
	var size := simulator.field_size
	var window := Vector2(get_viewport().get_visible_rect().size)
	var zoom := minf(window.x / (size.x + 8.0), window.y / (size.y + 8.0))
	return Vector2(zoom, zoom)


## ---------- overlay -------------------------------------------------------

func _build_hud() -> void:
	_hud = CanvasLayer.new()
	_hud.layer = 20
	add_child(_hud)

	# Anchored to the corners by their own edges rather than positioned by a guessed offset:
	# a panel that is 40 pixels too narrow silently eats the left of every line, which is how
	# the first version of this overlay printed "ENDER" and "M".
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UiTheme.panel_style(UiTheme.PANEL_DEEP))
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.offset_left = -404.0
	panel.offset_right = -8.0
	panel.offset_top = 8.0
	panel.offset_bottom = 8.0
	_hud.add_child(panel)
	_perf_label = UiTheme.label("", 13, UiTheme.TEXT)
	_perf_label.custom_minimum_size = Vector2(384.0, 0.0)
	panel.add_child(_perf_label)

	var bodies_panel := PanelContainer.new()
	bodies_panel.add_theme_stylebox_override("panel", UiTheme.panel_style(UiTheme.PANEL_DEEP))
	bodies_panel.anchor_top = 1.0
	bodies_panel.anchor_bottom = 1.0
	bodies_panel.anchor_left = 0.0
	bodies_panel.anchor_right = 0.0
	bodies_panel.offset_left = 12.0
	bodies_panel.offset_right = 492.0
	bodies_panel.offset_top = -184.0
	bodies_panel.offset_bottom = -8.0
	_hud.add_child(bodies_panel)
	_form_label = UiTheme.label("", 12, UiTheme.DIM)
	_form_label.custom_minimum_size = Vector2(468.0, 0.0)
	bodies_panel.add_child(_form_label)

	_hud.visible = _overlay_enabled


func _refresh_overlay() -> void:
	if not _overlay_enabled or _hud == null:
		return
	var frames := maxi(1, _frames_seen)
	var frame_ms := 0.0
	if not _frame_times.is_empty():
		frame_ms = _frame_times[frames - 1]
	var elapsed := float(Time.get_ticks_usec() - _run_start_usec) / 1000000.0
	var ticks_per_second := 0.0
	if elapsed > 0.0:
		ticks_per_second = float(simulator.tick_index) / elapsed
	# Rendering and simulation are reported apart on purpose: they are different quantities,
	# and a frame that runs several simulation ticks is where the difference shows.
	_perf_label.text = "\n".join([
		"RENDER %6.1f fps  frame %6.2f ms (worst %6.2f)" % [
			Engine.get_frames_per_second(), frame_ms, _frame_worst_ms()],
		"SIM    %6.1f t/s  %6.2f ms/tick (worst %6.2f)" % [
			ticks_per_second, _sim_average_ms(), _sim_worst_ms()],
		"BATTLE  t+%6.1fs  tick %6d  %d ticks/frame" % [
			simulator.elapsed, simulator.tick_index, _ticks_per_frame],
		"ALIVE   %3d v %3d   %d standing" % [
			simulator.side_count(SIDE_PLAYER), simulator.side_count(SIDE_ENEMY),
			simulator.side_count(SIDE_PLAYER) + simulator.side_count(SIDE_ENEMY)],
		"STAGE   %-14s hits %d  dead %d" % [_stage_label, _hits, _deaths],
	])
	var lines: PackedStringArray = []
	for body in simulator.formations:
		lines.append("%-14s %-9s coh %3.0f%%  %dx%d  %3d/%3d up" % [
			body.id, body.state_name(), body.cohesion * 100.0,
			body.file_count, body.rank_count, _living_in_body(body), body.size()])
	_form_label.text = "\n".join(lines)


func _living_in_body(body: BattleFormation) -> int:
	var living := 0
	for unit_id in body.unit_ids:
		var unit := simulator.find_unit(unit_id)
		if unit != null and unit.is_alive():
			living += 1
	return living


func _sim_average_ms() -> float:
	if _sim_usecs.is_empty():
		return 0.0
	return (_sim_total_usec / float(_sim_usecs.size())) / 1000.0


func _sim_worst_ms() -> float:
	var worst := 0.0
	for value in _sim_usecs:
		worst = maxf(worst, value)
	return worst / 1000.0


func _frame_worst_ms() -> float:
	var worst := 0.0
	for value in _frame_times:
		worst = maxf(worst, value)
	return worst


## ---------- the loop ------------------------------------------------------

func _process(delta: float) -> void:
	if simulator == null:
		return
	_frame_times.append(delta * 1000.0)
	_frames_seen += 1
	_rolling_fps.append(delta)
	if _rolling_fps.size() > 90:
		_rolling_fps.pop_front()

	if not _started:
		_started = true
		simulator.start()
		_run_start_usec = Time.get_ticks_usec()
		_stage = Stage.OPENING
		_stage_label = "opening"
		if _journal_path != "":
			journal = BattleJournal.open(_journal_path)
			if journal != null:
				journal.note_start(simulator, _seed)
		_request_shot("0_opening")

	if simulator.is_running():
		_ticks_this_frame = 0
		for i in _ticks_per_frame:
			if not simulator.is_running():
				break
			if simulator.tick_index >= _max_ticks:
				simulator.state = BattleSimulator.State.FINISHED
				break
			var tick_start := Time.get_ticks_usec()
			ai_player.update(simulator, TICK)
			ai_enemy.update(simulator, TICK)
			var events: Array[Dictionary] = simulator.step(TICK)
			var usec := Time.get_ticks_usec() - tick_start
			_sim_usecs.append(float(usec))
			_sim_total_usec += usec
			_ticks_this_frame += 1
			view.add_events(events)
			_consume_events(events)
			if journal != null:
				journal.observe(simulator)

	if _ticks_this_frame > 0:
		view.queue_redraw()
		if field != null:
			# Rebuilt on the tick, handed over once: the frames in between draw what the engine
			# already has. This is the renderer under measurement, so it is driven the same way
			# the battle scene drives it.
			field.pack(simulator)
			field.apply()
	_update_camera_pan(delta)
	_update_camera(delta)
	_advance_stage()
	_probe()
	_overlay_timer += delta
	if _overlay_timer >= 0.25:
		_overlay_timer = 0.0
		_refresh_overlay()
	_maybe_capture()
	if simulator.tick_index > 0 and simulator.tick_index % 500 == 0 and simulator.tick_index != _last_heartbeat:
		# A line every five hundred ticks, so a long run is legible while it runs rather than
		# only in its report.
		_last_heartbeat = simulator.tick_index
		print("  tick %6d  battle %6.1fs  wall %6.1fs  alive %d v %d  fps %.1f  sim %.2f ms/tick" % [
			simulator.tick_index, simulator.elapsed,
			float(Time.get_ticks_usec() - _run_start_usec) / 1000000.0,
			simulator.side_count(SIDE_PLAYER), simulator.side_count(SIDE_ENEMY),
			Engine.get_frames_per_second(), _sim_average_ms()])
	if simulator.is_finished():
		_finish_run()


func _consume_events(events: Array[Dictionary]) -> void:
	for event in events:
		_events_seen += 1
		match str(event.get("type", "")):
			"hit":
				_hits += 1
				if _first_hit_tick < 0:
					_first_hit_tick = simulator.tick_index
			"death":
				_deaths += 1
				if str(event.get("side", SIDE_ENEMY)) == SIDE_PLAYER:
					_deaths_player += 1
				else:
					_deaths_enemy += 1
			"finished":
				_finished_tick = simulator.tick_index


func _update_camera(delta: float) -> void:
	# The player's hands beat the film. Every one of these shots is of a battle that has been
	# framed for them; the moment they pan or zoom, the follow stops, and F hands it back.
	if camera_manual:
		return
	var size := simulator.field_size
	var target_zoom := _fit_zoom()
	var target_position := size * 0.5
	match _stage:
		Stage.OPENING, Stage.APPROACH:
			target_zoom = _fit_zoom() * 1.0
		Stage.CONTACT:
			target_zoom = _fit_zoom() * 2.3
			target_position = _battle_centre()
		Stage.MELEE:
			target_zoom = _fit_zoom() * 2.3
			target_position = _battle_centre()
		Stage.ATTRITION:
			target_zoom = _fit_zoom() * 1.7
			target_position = _battle_centre()
		Stage.RESULT, Stage.DONE:
			target_zoom = _fit_zoom() * 1.0
	var weight := clampf(delta * 3.0, 0.0, 1.0)
	camera.zoom = camera.zoom.lerp(target_zoom, weight)
	camera.position = camera.position.lerp(target_position, weight)


## ---------- camera controls ------------------------------------------------

## Middle mouse drags, the wheel zooms about the pointer, WASD or the arrows pan, and F hands the
## camera back to the film. Every one of them takes the camera out of the film's hands first, so what
## the player is looking at stays where they put it.
func _unhandled_input(event: InputEvent) -> void:
	if camera == null:
		return
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_camera(CAMERA_ZOOM_STEP)
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_camera(1.0 / CAMERA_ZOOM_STEP)
		elif button.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = button.pressed
			if button.pressed:
				camera_manual = true
		return
	if event is InputEventMouseMotion and _panning:
		camera_manual = true
		camera.position -= (event as InputEventMouseMotion).relative / camera.zoom.x
		_clamp_camera()
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F:
		camera_manual = false
		_clamp_camera()


## Zoom about the pointer, so the spot being looked at stays under it.
func _zoom_camera(step: float) -> void:
	camera_manual = true
	var before := camera.get_global_mouse_position()
	var zoom := clampf(camera.zoom.x * step, 0.15, 40.0)
	camera.zoom = Vector2(zoom, zoom)
	var after := camera.get_global_mouse_position()
	camera.position += before - after
	_clamp_camera()


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
	camera_manual = true
	camera.position += direction.normalized() * CAMERA_PAN_SPEED / maxf(0.2, camera.zoom.x) * delta
	_clamp_camera()


## Keep the view on the ground. A camera dragged off the field is watching nothing at all.
func _clamp_camera() -> void:
	if simulator == null:
		return
	var size := simulator.field_size
	camera.position = Vector2(
		clampf(camera.position.x, 0.0, size.x),
		clampf(camera.position.y, 0.0, size.y)
	)


## Where the fighting is: the mean position of the living, which is stable enough to film
## and does not jitter like a single soldier would.
func _battle_centre() -> Vector2:
	var total := Vector2.ZERO
	var counted := 0
	for unit in simulator.units:
		if unit.is_alive():
			total += unit.position
			counted += 1
	if counted == 0:
		return FIELD * 0.5
	return total / float(counted)


func _advance_stage() -> void:
	var living_player := simulator.side_count(SIDE_PLAYER)
	var living_enemy := simulator.side_count(SIDE_ENEMY)
	var living := living_player + living_enemy
	if _first_contact_tick < 0:
		for body in simulator.formations:
			if body.slots.size() > 0 and body.is_living():
				for unit_id in body.unit_ids:
					var unit := simulator.find_unit(unit_id)
					if unit == null or not unit.is_alive():
						continue
					if unit.auto_target_id >= 0 or unit.attack_order_target_id >= 0:
						var enemy := simulator.find_unit(unit.auto_target_id)
						if enemy != null and enemy.is_alive() and unit.position.distance_to(enemy.position) <= unit.attack_range + 2.0:
							_first_contact_tick = simulator.tick_index
							break
			if _first_contact_tick >= 0:
				break
	if _first_contact_tick < 0 and _first_hit_tick >= 0:
		_first_contact_tick = _first_hit_tick

	var next := _stage
	match _stage:
		Stage.OPENING:
			if simulator.tick_index >= 30:
				next = Stage.APPROACH
		Stage.APPROACH:
			if _first_contact_tick >= 0:
				next = Stage.CONTACT
		Stage.CONTACT:
			if simulator.tick_index >= _first_contact_tick + 150:
				next = Stage.MELEE
		Stage.MELEE:
			if living <= int(float(_per_side * 2) * 0.62):
				next = Stage.ATTRITION
		Stage.ATTRITION:
			if simulator.is_finished():
				next = Stage.RESULT
	if simulator.is_finished() and next != Stage.RESULT and next != Stage.DONE:
		next = Stage.RESULT
	if next != _stage:
		_stage = next
		_stage_label = ["opening", "approach", "first contact", "melee", "attrition", "result", "done"][_stage]
		_mark_stage()
		if _stage == Stage.CONTACT:
			_fps_at_contact = _rolling_fps_average()
		elif _stage == Stage.MELEE:
			_fps_at_melee = _rolling_fps_average()


func _rolling_fps_average() -> float:
	if _rolling_fps.is_empty():
		return 0.0
	var total := 0.0
	for value in _rolling_fps:
		total += value
	if total <= 0.0:
		return 0.0
	return float(_rolling_fps.size()) / total


## How many living soldiers can actually reach a living enemy, and how far the nearest
## enemy is. A line that has stopped killing is either a line that is not in contact or a
## line whose survivors are standing too far apart to reach each other, and those two look
## identical in a casualty count.
func _reachability() -> Dictionary:
	var living: Array[BattleUnit] = []
	for unit in simulator.units:
		if unit.is_alive():
			living.append(unit)
	var in_reach := 0
	var nearest_total := 0.0
	var nearest_worst := 0.0
	var counted := 0
	for unit in living:
		var nearest := INF
		for other in living:
			if other.side == unit.side:
				continue
			nearest = minf(nearest, unit.position.distance_to(other.position))
		if nearest == INF:
			continue
		counted += 1
		nearest_total += nearest
		nearest_worst = maxf(nearest_worst, nearest)
		if nearest <= unit.attack_range:
			in_reach += 1
	return {
		"living": living.size(),
		"nearest_enemy_average": 0.0 if counted == 0 else nearest_total / float(counted),
		"nearest_enemy_worst": nearest_worst,
		"soldiers_in_reach": in_reach,
		"soldiers_with_nobody_in_reach": maxi(0, counted - in_reach),
	}


func _mark_stage() -> void:
	var mark := {
		"stage": _stage_label,
		"tick": simulator.tick_index,
		"battle_seconds": simulator.elapsed,
		"wall_seconds": float(Time.get_ticks_usec() - _run_start_usec) / 1000000.0,
		"fps_now": _rolling_fps_average(),
		"fps_session": Engine.get_frames_per_second(),
		"sim_ms_per_tick": _sim_average_ms(),
		"living_player": simulator.side_count(SIDE_PLAYER),
		"living_enemy": simulator.side_count(SIDE_ENEMY),
		"deaths": _deaths,
		"hits": _hits,
		"reachability": _reachability(),
	}
	_stage_marks.append(mark)
	var label := str(mark["stage"]).replace(" ", "_")
	_request_shot("%d_%s" % [_stage, label])
	var reach: Dictionary = mark["reachability"]
	print("stage: %s at tick %d (%.1fs battle, %.1fs wall), fps %.1f, sim %.2f ms/tick, %d of %d in reach" % [
		mark["stage"], mark["tick"], mark["battle_seconds"], mark["wall_seconds"],
		mark["fps_now"], mark["sim_ms_per_tick"], int(reach["soldiers_in_reach"]), int(reach["living"])])


## ---------- physicality probe --------------------------------------------

## How close soldiers actually get to each other, sampled rather than every tick.
##
## This is the question the separation pass exists to answer, so it is measured rather
## than eyeballed: the closest pair in the whole battle, how many pairs are buried in
## each other, and the largest single-tick move anybody made (a launch, if there is one).
func _probe() -> void:
	if _probe_every <= 0 or simulator.tick_index % _probe_every != 0:
		return
	var cell := 4.0
	var buckets: Dictionary = {}
	for unit in simulator.units:
		if not unit.is_alive():
			continue
		var key := Vector2i(int(floor(unit.position.x / cell)), int(floor(unit.position.y / cell)))
		var bucket: Array = buckets.get(key, [])
		bucket.append(unit)
		buckets[key] = bucket

	var closest := 999.0
	var buried := 0
	for key: Vector2i in buckets.keys():
		var here: Array = buckets[key]
		for other_key in [key, key + Vector2i(1, 0), key + Vector2i(0, 1),
				key + Vector2i(1, 1), key + Vector2i(1, -1)]:
			if other_key == key:
				for i in here.size():
					for j in range(i + 1, here.size()):
						var d := (here[i] as BattleUnit).position.distance_to((here[j] as BattleUnit).position)
						closest = minf(closest, d)
						if d < 0.35:
							buried += 1
				continue
			var other: Array = buckets.get(other_key, [])
			for a in here:
				for b in other:
					var d2 := (a as BattleUnit).position.distance_to((b as BattleUnit).position)
					closest = minf(closest, d2)
					if d2 < 0.35:
						buried += 1
	if closest < 900.0:
		_probe_min_distance_sum += closest
		_probe_min_distance_worst = minf(_probe_min_distance_worst, closest)
		_probe_count += 1
	_probe_deep_pairs += buried

	# Movement ceiling: nobody may move further in one probe window than a soldier can
	# walk, plus the pass's own capped push. The window is the ticks that actually
	# passed rather than the ticks that were asked for, because a frame may run several.
	var window := float(maxi(1, simulator.tick_index - _last_probe_tick)) * TICK
	_last_probe_tick = simulator.tick_index
	var allowed := 8.0 * window + 3.0
	for unit in simulator.units:
		var previous: Variant = _last_positions.get(unit.id)
		if previous != null:
			var moved := (previous as Vector2).distance_to(unit.position)
			_launch_max = maxf(_launch_max, moved / window)
			if moved > allowed and unit.is_alive():
				print("  movement ceiling: unit %d moved %.2f units in %.2fs (allowed %.2f)" % [
					unit.id, moved, window, allowed])
		_last_positions[unit.id] = unit.position
	_probe_checks += 1


## ---------- capture and report -------------------------------------------

func _request_shot(name: String) -> void:
	if not _shots:
		return
	if _capture_busy:
		_shot_queued = name
		return
	_shot_pending = name


## Capture with the frame already drawn, so the image is the frame the player would have
## seen rather than the state before the camera moved.
func _maybe_capture() -> void:
	if _shot_pending.is_empty() or _capture_busy or not _shots:
		return
	_capture_busy = true
	var name := _shot_pending
	_shot_pending = ""
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [_out_dir, name]
	var error := image.save_png(path)
	if error == OK:
		var shot := {
			"file": path,
			"stage": _stage_label,
			"tick": simulator.tick_index,
			"battle_seconds": simulator.elapsed,
			"living_player": simulator.side_count(SIDE_PLAYER),
			"living_enemy": simulator.side_count(SIDE_ENEMY),
			"player_pixels": _count_pixels(image, "player"),
			"enemy_pixels": _count_pixels(image, "enemy"),
		}
		_shots_taken.append(shot)
		print("  shot: %s (tick %d, %d v %d standing)" % [
			path, shot["tick"], shot["living_player"], shot["living_enemy"]])
	else:
		print("  shot failed: %s (error %d)" % [path, error])
	_capture_busy = false
	if not _shot_queued.is_empty():
		_shot_pending = _shot_queued
		_shot_queued = ""


## Count team-coloured pixels, so "the armies are on the field and being drawn" is a
## number rather than an opinion. Coarse by design: it is a sanity check on the capture,
## not a renderer test.
func _count_pixels(image: Image, side: String) -> int:
	var wanted := Color("4fa8e0") if side == "player" else Color("d0603f")
	var count := 0
	var step := 4
	for y in range(0, image.get_height(), step):
		for x in range(0, image.get_width(), step):
			var pixel := image.get_pixel(x, y)
			if absf(pixel.r - wanted.r) < 0.14 and absf(pixel.g - wanted.g) < 0.14 \
					and absf(pixel.b - wanted.b) < 0.20:
				count += 1
	return count


func _finish_run() -> void:
	if _stage != Stage.RESULT and _stage != Stage.DONE:
		_stage = Stage.RESULT
		_stage_label = "result"
		_mark_stage()
		# The battle is over and the journal has nothing left to say about it.
		if journal != null:
			journal.close()
	# The final shot is requested early in the grace period rather than as the last thing
	# before writing: a capture that never completes (a window that stopped presenting, an
	# image the driver refused) must not be able to stop the report being written.
	if _stage == Stage.RESULT and _grace_frames == 20:
		_stage = Stage.DONE
		_stage_label = "done"
		_request_shot("9_result_final")
	if _grace_frames % 100 == 0:
		print("  finishing: tick %d, %d v %d standing, capture busy %s" % [
			simulator.tick_index, simulator.side_count(SIDE_PLAYER),
			simulator.side_count(SIDE_ENEMY), str(_capture_busy)])
	_grace_frames += 1
	if _grace_frames < 150:
		return
	_write_report()
	get_tree().quit()


func _write_report() -> void:
	var report := _build_report()
	var json := JSON.stringify(report, "  ")
	var text := _report_text(report)
	var json_path := "%s/showcase_report.json" % _out_dir
	var text_path := "%s/showcase_report.txt" % _out_dir
	var file := FileAccess.open(json_path, FileAccess.WRITE)
	if file != null:
		file.store_string(json)
		file.close()
	var text_file := FileAccess.open(text_path, FileAccess.WRITE)
	if text_file != null:
		text_file.store_string(text)
		text_file.close()
	print("showcase report written: %s" % text_path)
	print(text)


func _build_report() -> Dictionary:
	var frames := _frame_times.size()
	var frame_total := 0.0
	var frame_worst := 0.0
	var frame_samples: Array[float] = []
	for value in _frame_times:
		frame_total += value
		frame_worst = maxf(frame_worst, value)
		frame_samples.append(value)
	frame_samples.sort()
	var wall := float(Time.get_ticks_usec() - _run_start_usec) / 1000000.0
	var sim_samples: Array[float] = []
	var sim_total := 0.0
	var sim_worst := 0.0
	for value in _sim_usecs:
		sim_total += value
		sim_worst = maxf(sim_worst, value)
		sim_samples.append(value)
	sim_samples.sort()
	var percentile := func(samples: Array[float], fraction: float) -> float:
		if samples.is_empty():
			return 0.0
		var index := clampi(int(floor(float(samples.size() - 1) * fraction)), 0, samples.size() - 1)
		return samples[index]

	var bodies: Array[Dictionary] = []
	for body in simulator.formations:
		bodies.append({
			"id": body.id,
			"side": body.side,
			"living": _living_in_body(body),
			"size": body.size(),
			"state": body.state_name(),
			"cohesion": body.cohesion,
			"files": body.file_count,
			"ranks": body.rank_count,
			"anchor": [body.anchor.x, body.anchor.y],
		})

	return {
		"per_side": _per_side,
		"total_units": simulator.units.size(),
		"ticks_per_frame": _ticks_per_frame,
		"seed": _seed,
		"overlay": _overlay_enabled,
		"shots": _shots,
		"field": [FIELD.x, FIELD.y],
		"window": [WINDOW_SIZE.x, WINDOW_SIZE.y],
		"battle_clock_limit": simulator.max_duration,
		"unit_type": _unit_type,
		"enemy_unit_type": _enemy_unit_type,
		"sim_ticks": simulator.tick_index,
		"battle_seconds": simulator.elapsed,
		"wall_seconds": wall,
		"frames": frames,
		"render_fps_average": 0.0 if wall <= 0.0 else float(frames) / wall,
		"sim_ticks_per_second": 0.0 if wall <= 0.0 else float(simulator.tick_index) / wall,
		"frame_ms_average": 0.0 if frames == 0 else frame_total / float(frames),
		"frame_ms_p50": percentile.call(frame_samples, 0.5),
		"frame_ms_p95": percentile.call(frame_samples, 0.95),
		"frame_ms_p99": percentile.call(frame_samples, 0.99),
		"frame_ms_worst": frame_worst,
		"fps_min_observed": 0.0 if frame_worst <= 0.0 else 1000.0 / frame_worst,
		"fps_p95_frame": 1000.0 / maxf(0.001, percentile.call(frame_samples, 0.95)),
		"sim_ms_average": 0.0 if sim_samples.is_empty() else (sim_total / float(sim_samples.size())) / 1000.0,
		"sim_ms_p50": percentile.call(sim_samples, 0.5) / 1000.0,
		"sim_ms_p95": percentile.call(sim_samples, 0.95) / 1000.0,
		"sim_ms_p99": percentile.call(sim_samples, 0.99) / 1000.0,
		"sim_ms_worst": sim_worst / 1000.0,
		"fps_at_first_contact": _fps_at_contact,
		"fps_at_dense_melee": _fps_at_melee,
		"hits": _hits,
		"deaths": _deaths,
		"deaths_player": _deaths_player,
		"deaths_enemy": _deaths_enemy,
		"winner": simulator.winner,
		"first_hit_tick": _first_hit_tick,
		"first_contact_tick": _first_contact_tick,
		"finished_tick": _finished_tick,
		"living_player": simulator.side_count(SIDE_PLAYER),
		"living_enemy": simulator.side_count(SIDE_ENEMY),
		"formations": bodies,
		"stage_marks": _stage_marks,
		"shots_taken": _shots_taken,
		"physicality": {
			"probe_every_ticks": _probe_every,
			"checks": _probe_checks,
			"closest_pair_average": 0.0 if _probe_count == 0 else _probe_min_distance_sum / float(_probe_count),
			"closest_pair_worst": _probe_min_distance_worst,
			"buried_pairs_under_0.35": _probe_deep_pairs,
			"max_speed_units_per_second": _launch_max,
		},
		"overlap_report": simulator.overlap_report(),
	}


func _report_text(report: Dictionary) -> String:
	var lines: PackedStringArray = []
	lines.append("PROJECT BANNER - %d v %d BATTLE SHOWCASE" % [
		int(report["per_side"]), int(report["per_side"])])
	lines.append("field %.0fx%.0f   window %dx%d   seed %d   %d ticks/frame   overlay %s   battle clock %.0fs" % [
		float(report["field"][0]), float(report["field"][1]),
		int(report["window"][0]), int(report["window"][1]), int(report["seed"]),
		int(report["ticks_per_frame"]), "on" if bool(report["overlay"]) else "off",
		float(report["battle_clock_limit"])])
	lines.append("")
	lines.append("outcome: %s   %d sim ticks (%.1fs battle time) in %.1fs wall   winner %s" % [
		"resolved" if int(report["finished_tick"]) >= 0 else "unresolved",
		int(report["sim_ticks"]), float(report["battle_seconds"]), float(report["wall_seconds"]),
		str(report["winner"]) if not str(report["winner"]).is_empty() else "none"])
	lines.append("casualties: player %d dead, %d standing; enemy %d dead, %d standing (%d hits)" % [
		int(report["deaths_player"]), int(report["living_player"]),
		int(report["deaths_enemy"]), int(report["living_enemy"]), int(report["hits"])])
	lines.append("")
	lines.append("RENDER   average %.1f fps   min observed %.1f fps   p50 %.2f ms   p95 %.2f ms   p99 %.2f ms   worst %.2f ms" % [
		float(report["render_fps_average"]), float(report["fps_min_observed"]),
		float(report["frame_ms_p50"]), float(report["frame_ms_p95"]),
		float(report["frame_ms_p99"]), float(report["frame_ms_worst"])])
	lines.append("         fps at first contact %.1f   fps during dense melee %.1f" % [
		float(report["fps_at_first_contact"]), float(report["fps_at_dense_melee"])])
	lines.append("SIM      %.1f ticks/s   average %.2f ms/tick   p50 %.2f   p95 %.2f   p99 %.2f   worst %.2f ms" % [
		float(report["sim_ticks_per_second"]), float(report["sim_ms_average"]),
		float(report["sim_ms_p50"]), float(report["sim_ms_p95"]),
		float(report["sim_ms_p99"]), float(report["sim_ms_worst"])])
	lines.append("")
	lines.append("STAGES")
	for mark in _stage_marks:
		lines.append("  %-14s tick %6d  battle %6.1fs  wall %5.1fs  fps %5.1f  sim %5.2f ms/tick  alive %d v %d" % [
			str(mark["stage"]), int(mark["tick"]), float(mark["battle_seconds"]),
			float(mark["wall_seconds"]), float(mark["fps_now"]), float(mark["sim_ms_per_tick"]),
			int(mark["living_player"]), int(mark["living_enemy"])])
	lines.append("")
	lines.append("REACH PER STAGE (how many living soldiers had a living enemy inside their reach)")
	for mark in _stage_marks:
		var reach: Dictionary = mark["reachability"]
		lines.append("  %-14s %3d of %3d able to reach anybody, nearest enemy average %.2f units (worst %.2f)" % [
			str(mark["stage"]), int(reach["soldiers_in_reach"]), int(reach["living"]),
			float(reach["nearest_enemy_average"]), float(reach["nearest_enemy_worst"])])
	lines.append("")
	lines.append("PHYSICALITY (sampled every %d ticks, %d checks)" % [
		int(report["physicality"]["probe_every_ticks"]), int(report["physicality"]["checks"])])
	lines.append("  closest pair average %.3f units   worst %.3f units   buried pairs (<0.35) %d" % [
		float(report["physicality"]["closest_pair_average"]),
		float(report["physicality"]["closest_pair_worst"]),
		int(report["physicality"]["buried_pairs_under_0.35"])])
	lines.append("  fastest observed movement %.2f units/second" % [
		float(report["physicality"]["max_speed_units_per_second"])])
	lines.append("")
	lines.append("BODIES AT THE END")
	for body in report["formations"]:
		lines.append("  %-16s %d/%d up  %-10s coh %3.0f%%" % [
			str(body["id"]), int(body["living"]), int(body["size"]), str(body["state"]),
			float(body["cohesion"])])
	lines.append("")
	lines.append("SHOTS")
	for shot in _shots_taken:
		lines.append("  %s  tick %d  %d v %d standing  (player px %d, enemy px %d)" % [
			str(shot["file"]), int(shot["tick"]), int(shot["living_player"]),
			int(shot["living_enemy"]), int(shot["player_pixels"]), int(shot["enemy_pixels"])])
	return "\n".join(lines)
