extends Node
## The player's own settings, shared by the main menu and the Esc menu (D-137).
##
## Display only, deliberately: window mode, vsync and a frame cap are the knobs the game actually
## has. There is no sound system yet, and a volume slider attached to nothing is a lie - audio
## arrives with the first sound the game makes.
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
const VSYNC_LABELS: Array[String] = ["Off", "On"]
const VSYNC_VALUES: Array[bool] = [false, true]
const FPS_LABELS: Array[String] = ["Uncapped", "60", "120", "144", "240", "360"]
const FPS_CAPS: Array[int] = [0, 60, 120, 144, 240, 360]

## Where settings are read and written. Tests point this at their own file, exactly as the save
## suites do with their own save directory.
var path := PATH

var window_index := 1
var vsync_index := 1
var fps_index := 5


func _ready() -> void:
	if FileAccess.file_exists(path):
		load_settings()


## Read the file if it is there. [param apply_now] is false in tests: applying changes the actual
## window, and a suite must not resize the machine it runs on.
func load_settings(apply_now := true) -> bool:
	var config := ConfigFile.new()
	if config.load(path) != OK:
		return false
	window_index = clampi(int(config.get_value("display", "window_index", window_index)), 0,
		WINDOW_MODES.size() - 1)
	vsync_index = clampi(int(config.get_value("display", "vsync_index", vsync_index)), 0,
		VSYNC_VALUES.size() - 1)
	fps_index = clampi(int(config.get_value("display", "fps_index", fps_index)), 0,
		FPS_CAPS.size() - 1)
	if apply_now:
		apply()
	return true


func save_settings() -> void:
	var config := ConfigFile.new()
	config.set_value("display", "window_index", window_index)
	config.set_value("display", "vsync_index", vsync_index)
	config.set_value("display", "fps_index", fps_index)
	if config.save(path) != OK:
		DebugLogger.warn("settings: could not write %s" % path, "Settings")


## Push the current choices at the engine. Called on every change, so there is no OK button to
## forget and no state that only half-applied.
func apply() -> void:
	DisplayServer.window_set_mode(WINDOW_MODES[window_index])
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if VSYNC_VALUES[vsync_index] else DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = FPS_CAPS[fps_index]
	DebugLogger.info("settings applied: %s, vsync %s, fps cap %s" % [
		WINDOW_LABELS[window_index], VSYNC_LABELS[vsync_index], FPS_LABELS[fps_index],
	], "Settings")


## What a cycle button asks: the next index in a table, wrapping. Handles negatives, so a future
## "previous" is the same call with minus one.
static func next_index(index: int, count: int) -> int:
	if count <= 0:
		return 0
	return posmod(index + 1, count)
