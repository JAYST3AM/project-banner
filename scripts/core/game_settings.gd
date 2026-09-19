extends Node
## The player's own settings, shared by the main menu and the Esc menu (D-137).
##
## Display only, deliberately: window mode and size, UI scale, vsync and a frame cap are the knobs
## the game actually has. There is no sound system yet, and a volume slider attached to nothing is a
## lie - audio arrives with the first sound the game makes.
##
## Stored in `user://settings.cfg` and applied at startup only if the file exists, so a fresh
## install keeps the project's own defaults and a dev run's command-line flags stay strongest.

const PATH := "user://settings.cfg"

## The option tables are the single source of truth: the panels only cycle and print. Window mode is
## stored as an index into this table and mapped to the DisplayServer enum at apply time - what is
## saved is what the player chose, not a magic number.
const WINDOW_LABELS: Array[String] = ["Windowed", "Fullscreen"]
const WINDOW_MODES: Array[int] = [
	DisplayServer.WINDOW_MODE_WINDOWED,
	DisplayServer.WINDOW_MODE_FULLSCREEN,
]
const WINDOW_SIZE_LABELS: Array[String] = ["1280 x 720", "1600 x 900", "1920 x 1080", "2560 x 1440"]
const WINDOW_SIZES: Array[Vector2i] = [
	Vector2i(1280, 720), Vector2i(1600, 900), Vector2i(1920, 1080), Vector2i(2560, 1440),
]
const VSYNC_LABELS: Array[String] = ["Off", "On"]
const VSYNC_VALUES: Array[bool] = [false, true]
const FPS_LABELS: Array[String] = ["Uncapped", "60", "120", "144", "240", "360"]
const FPS_CAPS: Array[int] = [0, 60, 120, 144, 240, 360]
## UI scale: what every interface size is multiplied by. The slider's range and step live here so
## the panel and the service cannot disagree.
##
## The default is 0.8, not 1.0: the base sizes were tuned while every screen was being redressed,
## and at 1440p the owner's verdict on the result was "the default ui size needs to be much
## smaller". 0.8 is what the interface is meant to look like now; the slider can still go up.
const UI_SCALE_MIN := 0.6
const UI_SCALE_MAX := 1.4
const UI_SCALE_STEP := 0.05
const UI_SCALE_DEFAULT := 0.8

## Where settings are read and written. Tests point this at their own file, exactly as the save
## suites do with their own save directory.
var path := PATH

## Emitted when the player lets go of the UI-scale slider: screens that are already built hear it and
## build themselves again at the new size. Committed, not per tick - a rebuild per dragged pixel would
## tear the panel the player is dragging (D-137 follow-up).
signal ui_scale_committed

var window_index := 1
var window_size_index := 3
var ui_scale := UI_SCALE_DEFAULT
var vsync_index := 1
var fps_index := 5
## Whether the frame-rate overlay opens visible. F1 still toggles it by hand either way.
var show_perf_overlay := false
## Whether the map shows its one-line hint under the time controls.
var show_hints := true


func _ready() -> void:
	var had_file := FileAccess.file_exists(path)
	if had_file:
		load_settings()
	# A dev run's "--ui-scale=" wins over the file, because it is the more deliberate request.
	var forced := DevFlags.ui_scale()
	if forced > 0.0:
		ui_scale = clampf(forced, UI_SCALE_MIN, UI_SCALE_MAX)
		apply()
	elif not had_file:
		# Still apply once: PixelStyle's scale has to be told what the defaults are.
		apply()

	# A dev run can move the scale after boot: "--ui-scale-late=0.6" commits the change four seconds
	# in, which is how "does the slider reach the map's own interface" gets photographed.
	var late := DevFlags.ui_scale_late()
	if late > 0.0:
		get_tree().create_timer(4.0).timeout.connect(func() -> void:
			ui_scale = clampf(late, UI_SCALE_MIN, UI_SCALE_MAX)
			apply()
			commit_ui_scale())


## Read the file if it is there. [param apply_now] is false in tests: applying changes the actual
## window, and a suite must not resize the machine it runs on.
func load_settings(apply_now := true) -> bool:
	var config := ConfigFile.new()
	if config.load(path) != OK:
		return false
	window_index = clampi(int(config.get_value("display", "window_index", window_index)), 0,
		WINDOW_MODES.size() - 1)
	window_size_index = clampi(int(config.get_value("display", "window_size_index", window_size_index)),
		0, WINDOW_SIZES.size() - 1)
	ui_scale = clampf(float(config.get_value("display", "ui_scale", ui_scale)),
		UI_SCALE_MIN, UI_SCALE_MAX)
	vsync_index = clampi(int(config.get_value("display", "vsync_index", vsync_index)), 0,
		VSYNC_VALUES.size() - 1)
	fps_index = clampi(int(config.get_value("display", "fps_index", fps_index)), 0,
		FPS_CAPS.size() - 1)
	show_perf_overlay = bool(config.get_value("interface", "show_perf_overlay", show_perf_overlay))
	show_hints = bool(config.get_value("interface", "show_hints", show_hints))
	if apply_now:
		apply()
	return true


func save_settings() -> void:
	var config := ConfigFile.new()
	config.set_value("display", "window_index", window_index)
	config.set_value("display", "window_size_index", window_size_index)
	config.set_value("display", "ui_scale", ui_scale)
	config.set_value("display", "vsync_index", vsync_index)
	config.set_value("display", "fps_index", fps_index)
	config.set_value("interface", "show_perf_overlay", show_perf_overlay)
	config.set_value("interface", "show_hints", show_hints)
	if config.save(path) != OK:
		DebugLogger.warn("settings: could not write %s" % path, "Settings")


## The player let go of the scale slider: remember it, and tell every built screen to build itself
## again at the new size. The owner's report was that the slider changed the panel and nothing else -
## "the ui on the campaign map" stayed exactly as it was - because a control keeps the text size it
## was born with, and nothing had ever told the built screens to be born again.
func commit_ui_scale() -> void:
	save_settings()
	ui_scale_committed.emit()


## Push the current choices at the engine. Called on every change, so there is no OK button to
## forget and no state that only half-applied.
##
## The UI scale lives on [PixelStyle] as a static, because screens read it while building - a theme
## that is already built cannot be re-scaled, so the honest model is "the next screen built wears
## the new size", and the settings panel rebuilds itself so the change is visible where it is made.
func apply() -> void:
	DisplayServer.window_set_mode(WINDOW_MODES[window_index])
	if WINDOW_MODES[window_index] == DisplayServer.WINDOW_MODE_WINDOWED:
		DisplayServer.window_set_size(WINDOW_SIZES[window_size_index])
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if VSYNC_VALUES[vsync_index] else DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = FPS_CAPS[fps_index]
	PixelStyle.ui_scale = ui_scale
	# The overlay autoload may not exist yet when this runs at boot; it reads the same setting in its
	# own _ready, so a null here costs nothing.
	var overlay := get_node_or_null("/root/FpsOverlay")
	if overlay != null:
		(overlay as Node).visible = show_perf_overlay
	DebugLogger.info("settings applied: %s, ui %d%%, vsync %s, fps cap %s" % [
		WINDOW_LABELS[window_index], int(round(ui_scale * 100.0)),
		VSYNC_LABELS[vsync_index], FPS_LABELS[fps_index],
	], "Settings")


## What a cycle button asks: the next index in a table, wrapping. Handles negatives, so a future
## "previous" is the same call with minus one.
static func next_index(index: int, count: int) -> int:
	if count <= 0:
		return 0
	return posmod(index + 1, count)
