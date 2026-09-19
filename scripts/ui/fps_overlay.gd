extends CanvasLayer
## The frame rate, in the corner, on by default.
##
## Not a debug panel: the owner asks this machine for frames and wants to see them arriving, and a
## number that only appears after finding a hotkey is a number nobody reads. It shows what the rate
## is *against* as well as what it is, because "it is stuck at sixty" is a complaint about a ceiling
## rather than about the machine, and the two look identical when all you can see is a rate.
##
## The ceiling is read from the window, not from a project setting: this file claimed "vsync off"
## on a project with no such setting set, on the strength of the engine's frame cap alone, while the
## screen was synchronising every frame at three hundred and forty-three of its three hundred and
## sixty. A label that disagrees with the number beside it is worse than no label.
##
## Frames are counted here and the rate is worked out over a window rather than read from
## Engine.get_frames_per_second(), so the number moves when the machine does instead of when the
## engine decides to sample it.

## How long a reading covers. A quarter of a second is long enough to be steady and short enough
## that a stall shows up while it is still happening.
const SAMPLE_SECONDS := 0.25
## A frame this slow is called out the moment it happens when the frame log is on: the tail is what
## a "runs fine" claim gets wrong, and the average never shows it.
const HITCH_MS := 25.0

var _label: Label = null
var _frames := 0
var _elapsed := 0.0
## The worst single frame in the window, in milliseconds: a good average with a bad tail is what a
## hitch looks like from the inside.
var _worst_ms := 0.0
## Whether this run asked for the frame pacing on the record ("--framelog").
var _log_frames := false


func _ready() -> void:
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS
	_log_frames = DevFlags.framelog()
	_build()


func _build() -> void:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UiTheme.panel_style(UiTheme.PANEL_DEEP))
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.position = Vector2(12.0, 12.0)
	add_child(panel)
	_label = UiTheme.label("", 13, UiTheme.TEXT)
	panel.add_child(_label)


func _process(delta: float) -> void:
	_frames += 1
	_elapsed += delta
	_worst_ms = maxf(_worst_ms, delta * 1000.0)
	if _log_frames and delta * 1000.0 >= HITCH_MS:
		DebugLogger.warn("hitch: %.1f ms" % (delta * 1000.0), "Perf")
	if _elapsed < SAMPLE_SECONDS:
		return
	var fps := float(_frames) / _elapsed
	var ms := _elapsed * 1000.0 / float(_frames)
	if _log_frames:
		DebugLogger.info("frame: %.0f fps, avg %.2f ms, worst %.1f ms, process %.2f ms" % [
			fps, ms, _worst_ms, Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		], "Perf")
	_label.text = "%s   ·   %.2f ms   ·   %s" % [
		_rate_text(fps), ms, _limit_text()]
	_label.add_theme_color_override("font_color", _rate_colour(fps))
	_frames = 0
	_elapsed = 0.0
	_worst_ms = 0.0


func _rate_text(fps: float) -> String:
	return "%.0f fps" % fps


## The colour says one thing: is the machine keeping up with the screen it is drawing to. Sixty is
## the line because that is the commonest refresh rate and the game's own clock is not tied to it.
func _rate_colour(fps: float) -> Color:
	if fps >= 60.0:
		return UiTheme.TEXT
	return Color(0.95, 0.75, 0.35) if fps >= 30.0 else Color(0.95, 0.35, 0.30)


## What is holding the rate where it is. An uncapped engine and a capped one look the same from a
## frame rate alone, and the difference decides whether the machine or a setting owns the number.
func _limit_text() -> String:
	var parts: Array[String] = []
	var mode := DisplayServer.window_get_vsync_mode()
	if mode == DisplayServer.VSYNC_DISABLED:
		# Only when the synchronisation is genuinely off is the rate the machine's own. With it on,
		# the ceiling is the screen's, and a frame cap on top of that is a second ceiling nobody
		# needs to read about.
		parts.append("vsync off")
		var cap := Engine.max_fps
		parts.append("uncapped" if cap <= 0 else "cap %d" % cap)
	else:
		var hz := DisplayServer.screen_get_refresh_rate()
		parts.append("vsync on" if hz <= 0.0 else "vsync on   ·   %.0f Hz screen" % hz)
	return "   ·   ".join(parts)
