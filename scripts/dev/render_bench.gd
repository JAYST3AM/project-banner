extends Node2D
## Windowed render benchmark. Development tooling only - it is not part of the game and
## nothing in the game reads it.
##
## [b]What it is for.[/b] Every number in this repository measures the [i]simulation[/i].
## [code]docs/CURRENT_STATE.md[/code] says so plainly in its own limits: "rendering is not in
## any of these measurements", and drawing twenty thousand soldiers was a problem left for
## "the large-battle milestone". The Step 7.9 render spike opens by putting a number on that
## problem before changing anything about it: this scene builds a real battle through the
## production constructors, freezes the simulation, and then draws the same frozen army in
## several ways, one mode at a time, with vsync off and the frame rate uncapped. Frame time is
## therefore what the machine actually costs.
##
## [b]What it measures, and what it does not.[/b] Milliseconds a frame, for the ground alone,
## for the per-soldier canvas path the game uses today, and for the instanced path. It does
## not measure the simulation: the battle is stepped a fixed number of ticks first and then
## left alone for the whole measurement, because a tick at twenty thousand soldiers costs
## hundreds of milliseconds and would bury the number this scene exists to produce. The tick
## cost is printed separately, from the warm-up, so the two are never confused.
##
## [b]Honest limits, stated here rather than discovered later.[/b] The instanced path draws
## bodies and outlines only: health bars, facing pips, ranged rings, selection rings and order
## lines are per-soldier overlays it does not build yet. The per-soldier mode draws all of
## them, because that is what the game does today. A comparison between the two is therefore a
## comparison of what exists, and the report says which overlays are missing from the newer
## path rather than implying the two draw the same picture.
##
## Usage (windowed - there is nothing to see headlessly):
## [codeblock]
## godotc --path "<project>" res://scenes/dev/render_bench.tscn -- \
##     --per-side=10000 --ticks=2 --frames=30 --out="F:/VSC Projects/pb-bench/render"
## [/codeblock]
## Switches: [code]--per-side=[/code], [code]--seed=[/code], [code]--ticks=[/code],
## [code]--frames=[/code], [code]--warmup=[/code], [code]--fill=setters|buffer|both[/code],
## [code]--modes=terrain,immediate,field[/code], [code]--zoom=[/code] (0 = fit the field),
## [code]--out=[/code], [code]--label=[/code], [code]--overlay=[/code].

const TICK := 0.05
const FIELD := Vector2(200.0, 120.0)
const WINDOW_SIZE := Vector2i(1600, 900)
const SIDE_PLAYER := BattleContext.SIDE_PLAYER
const SIDE_ENEMY := BattleContext.SIDE_ENEMY

const DEFAULT_MODES := "terrain,immediate,field"

var _per_side := 300
var _seed := 70707
var _ticks := 2
var _frames := 30
var _warmup := 5
var _fill := "setters"
var _modes_arg := DEFAULT_MODES
var _zoom := 0.0
var _out_dir := "F:/VSC Projects/pb-bench/render"
var _label := "render"
var _overlay_enabled := true

var config: GameConfig = null
var catalog: FormationCatalog = null
var units_catalog: UnitCatalog = null
var context: BattleContext = null
var simulator: BattleSimulator = null
var view: BattleView = null
var field: SoldierField = null
var camera: Camera2D = null

## One entry per mode: the name, whether the view draws the soldiers, whether the field does,
## and which fill the field should use.
var _modes: Array[Dictionary] = []
var _mode_index := 0
var _frame_index := 0
var _samples: PackedFloat32Array = PackedFloat32Array()
var _fill_samples: PackedFloat32Array = PackedFloat32Array()
## The published-buffer mode's own cost, measured apart from the per-frame assignment: the
## rebuild happens where the simulation changes, not where the frame does.
var _repack_samples: PackedFloat32Array = PackedFloat32Array()
var _repack_every := 15
var _results: Array[Dictionary] = []
var _sim_usecs: PackedFloat32Array = PackedFloat32Array()
var _ready_reported := false
var _done := false
var _buffer_layout: Dictionary = {}
var _report_path := ""
## Frames drawn before anything is measured or stepped. The first frames of a windowed run
## are the engine's, not the scene's - pipelines compile, the terrain is uploaded the first
## time it is drawn - and a simulation tick measured inside that window reports seconds for
## work that costs milliseconds once the window has settled.
var _startup_frames := 5
## Ticks still to step before the measurement begins.
var _ticks_pending := 0
## Whether the simulation keeps running while the frames are measured. Off, the measurement is
## the renderer's cost alone; on, it is the whole game - simulation and drawing in the same
## frame, which is the only shape in which an fps figure means what a player would see. Both
## are reported, and the report says which one it is.
var _live := false
## How many ticks each measured frame runs when the simulation is live.
var _live_ticks := 1
## The live mode's simulation cost, measured per frame so the two halves of a frame can be
## reported apart instead of being blamed on each other.
var _live_sim: PackedFloat32Array = PackedFloat32Array()
## The previous frame's wall clock, and the engine's own delta for the same frame. Godot's
## [code]delta[/code] is not the frame-to-frame wall time - it is smoothed, and a frame short
## enough to hide a several-hundred-millisecond tick behind a 133 ms reading was caught doing
## exactly that - so the frame time this harness reports is measured here, with the engine's
## figure kept beside it as a cross-check.
var _last_wall_usec := 0
var _engine_delta_samples: PackedFloat32Array = PackedFloat32Array()

## Overlay, so a windowed run can be watched while it happens.
var _hud: CanvasLayer = null
var _label_node: Label = null


func _ready() -> void:
	_parse_args()
	# Uncapped and unsynchronised: a vsynced frame time belongs to the monitor, not to the
	# renderer, and the whole point of this scene is the renderer's number.
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DisplayServer.window_set_size(WINDOW_SIZE)
	get_window().size = WINDOW_SIZE
	DirAccess.make_dir_recursive_absolute(_out_dir)
	config = GameManager.config()
	catalog = FormationCatalog.load_from()
	units_catalog = UnitCatalog.load_from()
	_build_modes()
	_build_battle()
	_build_hud()
	print("render bench: %d v %d deployed (%d soldiers), %d formations, field %.0fx%.0f, zoom %.2f, window %dx%d" % [
		simulator.side_count(SIDE_PLAYER), simulator.side_count(SIDE_ENEMY),
		simulator.units.size(), simulator.formations.size(),
		FIELD.x, FIELD.y, camera.zoom.x, WINDOW_SIZE.x, WINDOW_SIZE.y])
	print("setup checksum %d:%s" % [
		simulator.units.size(), ShowcaseBattle.setup_checksum(simulator.units)])
	print("buffer probe: %s" % [_describe_layout(_buffer_layout)])
	print("modes: %s" % [_mode_names()])


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--per-side="):
			_per_side = maxi(2, int(arg.substr(11)))
		elif arg.begins_with("--seed="):
			_seed = int(arg.substr(7))
		elif arg.begins_with("--ticks="):
			_ticks = maxi(0, int(arg.substr(8)))
		elif arg.begins_with("--frames="):
			_frames = maxi(1, int(arg.substr(9)))
		elif arg.begins_with("--warmup="):
			_warmup = maxi(0, int(arg.substr(9)))
		elif arg.begins_with("--startup="):
			_startup_frames = maxi(0, int(arg.substr(10)))
		elif arg.begins_with("--repack-every="):
			_repack_every = maxi(1, int(arg.substr(15)))
		elif arg.begins_with("--live-ticks="):
			_live_ticks = maxi(1, int(arg.substr(13)))
		elif arg.begins_with("--live="):
			_live = arg.substr(7).to_int() != 0
		elif arg.begins_with("--fill="):
			_fill = arg.substr(7)
		elif arg.begins_with("--modes="):
			_modes_arg = arg.substr(8)
		elif arg.begins_with("--zoom="):
			_zoom = maxf(0.0, float(arg.substr(7)))
		elif arg.begins_with("--out="):
			_out_dir = arg.substr(6)
		elif arg.begins_with("--label="):
			_label = arg.substr(8)
		elif arg.begins_with("--overlay="):
			_overlay_enabled = arg.substr(10).to_int() != 0


## Turn the requested modes into the list the loop walks. [code]--fill=both[/code] is the
## honest way to compare the two ways of writing instance data in one run: same battle, same
## frozen frame, one after the other.
func _build_modes() -> void:
	_modes = []
	for raw in _modes_arg.split(",", false):
		var name := raw.strip_edges()
		if name == "terrain":
			_modes.append({"name": "terrain only", "view_units": false, "field": false, "fill": "setters"})
		elif name == "block":
			_modes.append({"name": "block view (scale boxes)", "view_units": true, "field": false, "fill": "setters", "block": true})
		elif name == "immediate":
			_modes.append({"name": "immediate (canvas per soldier)", "view_units": true, "field": false, "fill": "setters"})
		elif name == "field":
			if _fill == "both":
				_modes.append({"name": "field: setters", "view_units": false, "field": true, "fill": "setters"})
				_modes.append({"name": "field: buffer", "view_units": false, "field": true, "fill": "buffer"})
			else:
				_modes.append({"name": "field: %s" % _fill, "view_units": false, "field": true, "fill": _fill})
		elif name == "published":
			_modes.append({"name": "field: published buffer", "view_units": false, "field": true, "fill": "published"})
	if _modes.is_empty():
		_modes.append({"name": "immediate (canvas per soldier)", "view_units": true, "field": false, "fill": "setters"})


func _mode_names() -> String:
	var names: PackedStringArray = []
	for mode in _modes:
		names.append(str(mode["name"]))
	return ", ".join(names)


## The battle is the production one, built by the production constructors, so what is drawn
## here is what the game draws. The simulation is then stepped a fixed number of ticks and
## left alone for the whole measurement.
func _build_battle() -> void:
	var built := ShowcaseBattle.build(config, units_catalog, catalog, _per_side, _seed)
	context = built["context"]
	simulator = built["simulator"]

	view = BattleView.new()
	add_child(view)
	view.bind(simulator, context)
	# The development overlay stays off: this scene measures the army and the ground, and the
	# overlay is hundreds of canvas commands that belong to a different question.
	view.show_formation_debug = false
	view.show_formation_labels = false

	field = SoldierField.new()
	add_child(field)
	field.build(simulator.units.size())
	_buffer_layout = field.probe_buffer_layout()
	field.visible = false

	camera = Camera2D.new()
	add_child(camera)
	camera.make_current()
	camera.position = FIELD * 0.5
	camera.zoom = _fit_zoom()

	simulator.start()
	_ticks_pending = _ticks
	_sim_usecs = PackedFloat32Array()


func _fit_zoom() -> Vector2:
	if _zoom > 0.0:
		return Vector2(_zoom, _zoom)
	var window := Vector2(get_viewport().get_visible_rect().size)
	var zoom := minf(window.x / (FIELD.x + 8.0), window.y / (FIELD.y + 8.0))
	return Vector2(zoom, zoom)


func _describe_layout(layout: Dictionary) -> String:
	if not bool(layout.get("ok", false)):
		return "unreadable - the buffer path will fall back to setters"
	var parts: PackedStringArray = []
	for key in ["stride", "x_x", "y_y", "origin_x", "origin_y", "color"]:
		parts.append("%s=%d" % [key, int(layout.get(key, -1))])
	return ", ".join(parts)


func _build_hud() -> void:
	_hud = CanvasLayer.new()
	_hud.layer = 20
	add_child(_hud)
	_label_node = Label.new()
	_label_node.position = Vector2(12.0, 8.0)
	_label_node.add_theme_font_size_override("font_size", 14)
	_hud.add_child(_label_node)
	_hud.visible = _overlay_enabled


## ---------- the loop ------------------------------------------------------

func _process(delta: float) -> void:
	if _done or simulator == null:
		return
	# The frame time this harness reports, measured rather than asked for: the wall clock at the
	# top of this frame against the wall clock at the top of the previous one. Godot's delta is
	# smoothed and is kept only as a cross-check.
	var now_usec := Time.get_ticks_usec()
	var wall_ms := 0.0
	if _last_wall_usec > 0:
		wall_ms = float(now_usec - _last_wall_usec) / 1000.0
	_last_wall_usec = now_usec
	if _startup_frames > 0:
		_startup_frames -= 1
		view.queue_redraw()
		if _label_node != null:
			_label_node.text = "warming up (%d frames left)" % _startup_frames
		return
	if _ticks_pending > 0:
		while _ticks_pending > 0:
			var started := Time.get_ticks_usec()
			simulator.step(TICK)
			var usec := float(Time.get_ticks_usec() - started) / 1000.0
			_sim_usecs.append(usec)
			print("tick %d stepped in %.1f ms" % [simulator.tick_index, usec])
			_ticks_pending -= 1
		_apply_mode()
		return
	if not _ready_reported:
		_ready_reported = true
		if _label_node != null:
			_label_node.text = "measuring: %s" % str(_modes[_mode_index]["name"])
	if _frame_index >= _warmup:
		_samples.append(wall_ms)
		_engine_delta_samples.append(delta * 1000.0)
	var mode := _modes[_mode_index]
	if _live:
		# The whole game, in the frame, the way a player gets it: simulation first, then the
		# drawing of what it decided. The two are timed apart so an fps figure can say which
		# half it is paying for, and the warm-up frames are excluded here too - the first tick of
		# a battle is the cold one (grid build, kernel load) and would otherwise be averaged into
		# the figure as if it happened every frame.
		var tick_start := Time.get_ticks_usec()
		for i in _live_ticks:
			if simulator.is_running():
				simulator.step(TICK)
		if _frame_index >= _warmup:
			_live_sim.append(float(Time.get_ticks_usec() - tick_start) / 1000.0)
	if bool(mode["field"]):
		if str(mode["fill"]) == "published":
			if _live or _frame_index % _repack_every == 0:
				var packed := field.pack(simulator)
				_repack_samples.append(float(packed.get("usec", 0)) / 1000.0)
			var applied := field.apply()
			_fill_samples.append(float(applied.get("usec", 0)) / 1000.0)
		else:
			var stats := field.update_from(simulator)
			_fill_samples.append(float(stats.get("usec", 0)) / 1000.0)
	view.queue_redraw()
	if _label_node != null:
		_label_node.text = "%-34s frame %6.2f ms   %5.1f fps   sample %d/%d" % [
			str(mode["name"]), delta * 1000.0, 1000.0 / maxf(0.0001, delta),
			_samples.size(), _frames]
	_frame_index += 1
	if _frame_index >= _warmup + _frames:
		_finish_mode()


func _apply_mode() -> void:
	var mode := _modes[_mode_index]
	view.show_units = bool(mode["view_units"])
	# The scale ladder's own path: boxes at the level the camera's zoom asks for, never individuals.
	# This is the picture the large battles are meant to be watched at, and it was the one mode the
	# benchmark did not have. See D-117.
	view.block_view = bool(mode.get("block", false))
	field.visible = bool(mode["field"])
	field.fill_mode = str(mode["fill"])
	view.queue_redraw()


func _finish_mode() -> void:
	var mode := _modes[_mode_index]
	var stats := _stats(_samples)
	stats["name"] = str(mode["name"])
	stats["fill_ms"] = _average(_fill_samples)
	stats["fill_p95_ms"] = _percentile(_fill_samples, 0.95)
	stats["fill_mode"] = str(mode["fill"]) if bool(mode["field"]) else "-"
	stats["frames"] = _samples.size()
	stats["repack_ms"] = _average(_repack_samples)
	stats["repack_every"] = _repack_every if not _repack_samples.is_empty() else 0
	stats["sim_ms"] = _average(_live_sim)
	stats["engine_ms"] = _average(_engine_delta_samples)
	_results.append(stats)
	print(_format_result(stats))
	_mode_index += 1
	_frame_index = 0
	_samples = PackedFloat32Array()
	_fill_samples = PackedFloat32Array()
	_repack_samples = PackedFloat32Array()
	_engine_delta_samples = PackedFloat32Array()
	if _mode_index >= _modes.size():
		_finish()
		return
	_apply_mode()


func _format_result(stats: Dictionary) -> String:
	var line := "%-32s frames %4d   avg %8.2f ms   p50 %8.2f   p95 %8.2f   worst %9.2f   %6.1f fps" % [
		str(stats["name"]), int(stats["frames"]), float(stats["avg"]),
		float(stats["p50"]), float(stats["p95"]), float(stats["worst"]), 1000.0 / maxf(0.0001, float(stats["avg"]))]
	if float(stats["fill_ms"]) > 0.0:
		line += "   | per frame %6.2f ms avg (p95 %6.2f)" % [
			float(stats["fill_ms"]), float(stats["fill_p95_ms"])]
	if int(stats["repack_every"]) > 0:
		line += "   | repack %7.2f ms every %d frames (amortised %5.2f ms/frame)" % [
			float(stats["repack_ms"]), int(stats["repack_every"]),
			float(stats["repack_ms"]) / float(stats["repack_every"])]
	if float(stats["sim_ms"]) > 0.0:
		line += "   | sim %6.2f ms/tick inside these frames" % float(stats["sim_ms"])
	if float(stats["engine_ms"]) > 0.0:
		line += "   | engine delta %6.2f ms" % float(stats["engine_ms"])
	return line


func _finish() -> void:
	_done = true
	var sim_ms := _average(_sim_usecs)
	var tick_text: PackedStringArray = []
	for value in _sim_usecs:
		tick_text.append("%.1f" % value)
	var lines: PackedStringArray = []
	lines.append("=== render bench: %s ===" % _label)
	lines.append("soldiers %d (%d v %d), seed %d, field %.0fx%.0f, zoom %.2f, window %dx%d, terrain cells %d" % [
		simulator.units.size(), simulator.side_count(SIDE_PLAYER), simulator.side_count(SIDE_ENEMY),
		_seed, FIELD.x, FIELD.y, camera.zoom.x, WINDOW_SIZE.x, WINDOW_SIZE.y,
		simulator.terrain.cell_count() if simulator.terrain != null else 0])
	lines.append("setup checksum %s" % ShowcaseBattle.setup_checksum(simulator.units))
	if _live:
		lines.append("simulation: LIVE - %d tick(s) run inside every measured frame, so these frame "
			% _live_ticks + "times are what a player gets: simulation and drawing together")
	else:
		lines.append("simulation: %d ticks stepped after the window settled, %.1f ms/tick average [%s] " % [
			_sim_usecs.size(), sim_ms, ", ".join(tick_text)]
			+ "- frozen for every frame below, so these are render costs and nothing else")
	lines.append("buffer probe: %s" % _describe_layout(_buffer_layout))
	lines.append("the instanced path draws bodies, health bars and facing pips; the ranged ring is "
		+ "not built yet, and selection rings and order lines stay on the canvas path because their "
		+ "cost follows what a player has selected rather than the size of the army")
	for stats in _results:
		lines.append(_format_result(stats))
	var text := "\n".join(lines)
	print("")
	print(text)
	_report_path = "%s/%s_%d.txt" % [_out_dir, _label, simulator.units.size()]
	var file := FileAccess.open(_report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(text + "\n")
		file.close()
		print("report written to %s" % _report_path)
	get_tree().quit(0)


## ---------- statistics ----------------------------------------------------

func _stats(samples: PackedFloat32Array) -> Dictionary:
	if samples.is_empty():
		return {"avg": 0.0, "p50": 0.0, "p95": 0.0, "worst": 0.0}
	var sorted := samples.duplicate()
	sorted.sort()
	return {
		"avg": _average(samples),
		"p50": _percentile(sorted, 0.5),
		"p95": _percentile(sorted, 0.95),
		"worst": sorted[sorted.size() - 1],
	}


func _average(values: PackedFloat32Array) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for value in values:
		total += value
	return total / float(values.size())


func _percentile(values: PackedFloat32Array, fraction: float) -> float:
	if values.is_empty():
		return 0.0
	var index := int(clampf(round(fraction * float(values.size() - 1)), 0.0, float(values.size() - 1)))
	return values[index]
