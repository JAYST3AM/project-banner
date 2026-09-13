extends Node2D
## Boot scene.
##
## Shows the project banner for a moment in a windowed run, then hands control to
## the main menu. In a headless run the splash is skipped entirely so validation
## runs and the test harness are never delayed by presentation code.

const TITLE := "PROJECT BANNER"
const SUBTITLE := "Development Environment Operational"
const SPLASH_SECONDS := 1.1

@onready var _title: Label = $UI/Title
@onready var _subtitle: Label = $UI/Subtitle


func _ready() -> void:
	SceneManager.adopt_initial_scene()
	_title.text = TITLE
	_subtitle.text = SUBTITLE
	print("[Main] %s - %s" % [TITLE, SUBTITLE])
	print("[Main] Godot %s | build %s | Project Banner v%s" % [
		Engine.get_version_info().get("string", "unknown"),
		Engine.get_version_info().get("build", "unknown"),
		ProjectSettings.get_setting("application/config/version", "0.0.0"),
	])

	var wait := 0.0 if _is_headless() else SPLASH_SECONDS
	if wait > 0.0:
		await get_tree().create_timer(wait).timeout
	SceneManager.change_scene("main_menu")


func _is_headless() -> bool:
	return DisplayServer.get_name() == "headless" or OS.get_cmdline_args().has("--headless")
