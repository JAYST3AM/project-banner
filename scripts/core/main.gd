extends Node2D
## Boot scene.
##
## Shows the project banner for a moment in a windowed run, then hands control to
## the main menu. In a headless run the splash is skipped entirely so validation
## runs and the test harness are never delayed by presentation code.

const TITLE := "PROJECT BANNER"
const SUBTITLE := "Development Environment Operational"
const SPLASH_SECONDS := 1.1
const SCREENSHOT_PROBE := preload("res://scripts/dev/screenshot_probe.gd")
const LAYOUT_WATCHER := preload("res://scripts/dev/layout_edit_watcher.gd")

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
	DebugLogger.info("device: %s" % DeviceReport.one_line(), "Main")

	var wait := 0.0 if _is_headless() else SPLASH_SECONDS
	if wait > 0.0:
		await get_tree().create_timer(wait).timeout

	# Before the branch, so a screenshot run gets its shot whether it starts a campaign or just
	# sits on the menu. The probe lives on the tree root: this scene is about to be replaced.
	_spawn_screenshot_probe()
	_spawn_layout_watcher()

	var autostart := DevFlags.autostart_campaign()
	if bool(autostart.get("enabled", false)):
		DebugLogger.info("dev flag: autostarting a campaign", "Main")
		GameManager.new_campaign(str(autostart.get("name", "Dev Campaign")), int(autostart.get("seed", 0)))
		SceneManager.change_scene("world_map")
		return

	# Dev-only: "--new-campaign" opens the New Campaign screen directly (D-168). The
	# screen normally opens from the menu's New Campaign button, and a script or a
	# screenshot cannot click through the menu to reach it.
	if DevFlags.new_campaign():
		DebugLogger.info("dev flag: opening the new campaign screen", "Main")
		SceneManager.change_scene("new_campaign", {"campaign_name": "Dev Company", "seed_value": 5150})
		return

	SceneManager.change_scene("main_menu")


## Dev-only: "--screenshot=<path>" saves the game's own pixels once the scene has arrived, with
## "--screenshot-delay=<ms>" to wait and "--screenshot-quit" to close up after. The work is done by a
## probe parented to the tree root, because this scene is replaced almost immediately.
func _spawn_screenshot_probe() -> void:
	if DevFlags.screenshot_path().is_empty():
		return
	var probe := Node.new()
	probe.name = "ScreenshotProbe"
	probe.set_script(SCREENSHOT_PROBE)
	get_tree().root.add_child.call_deferred(probe)


## Dev-only: "--layout-edit" attaches the layout editor to every screen as it opens. The
## watcher lives on the tree root, because screens come and go beneath it.
func _spawn_layout_watcher() -> void:
	if not DevFlags.layout_edit():
		return
	var watcher := Node.new()
	watcher.name = "LayoutEditWatcher"
	watcher.set_script(LAYOUT_WATCHER)
	get_tree().root.add_child.call_deferred(watcher)


func _is_headless() -> bool:
	return DisplayServer.get_name() == "headless" or OS.get_cmdline_args().has("--headless")
