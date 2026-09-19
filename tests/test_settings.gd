extends TestCase
## The settings service and its option tables (D-137): window mode, vsync, frame cap.
##
## What this suite exists to pin down:
## [br]- every option has both a label and a value, so a cycle button can never run off a table;
## [br]- cycling wraps at both ends, including a nonsense empty table;
## [br]- choices survive a save and a load - to the test's own file, never the player's, and the
##   player's live values are put back afterwards.

const TEST_PATH := "user://settings_test.cfg"


func run() -> void:
	await _tick()
	_test_option_tables_line_up()
	_test_scale_bounds()
	_test_scaled_sizes()
	_test_scale_commit_announces()
	_test_cycling_wraps()
	_test_save_and_load_round_trip()
	_complete()


func _test_option_tables_line_up() -> void:
	section("every option has a label and a value")
	equal(GameSettings.WINDOW_LABELS.size(), GameSettings.WINDOW_MODES.size(),
		"window labels and modes")
	equal(GameSettings.WINDOW_SIZE_LABELS.size(), GameSettings.WINDOW_SIZES.size(),
		"window size labels and sizes")
	equal(GameSettings.VSYNC_LABELS.size(), GameSettings.VSYNC_VALUES.size(),
		"vsync labels and values")
	equal(GameSettings.FPS_LABELS.size(), GameSettings.FPS_CAPS.size(),
		"frame cap labels and values")
	greater(GameSettings.WINDOW_LABELS.size(), 1, "and there is more than one window mode to choose")


func _test_scale_bounds() -> void:
	section("the UI scale stays inside its slider's range")
	greater(GameSettings.UI_SCALE_MAX, GameSettings.UI_SCALE_MIN, "the range has room")
	greater(GameSettings.UI_SCALE_STEP, 0.0, "the step moves")
	check(GameSettings.UI_SCALE_DEFAULT >= GameSettings.UI_SCALE_MIN
		and GameSettings.UI_SCALE_DEFAULT <= GameSettings.UI_SCALE_MAX,
		"and the default sits inside the slider, wherever it is tuned to")


func _test_scaled_sizes() -> void:
	section("every interface size passes through the same arithmetic")
	var kept := PixelStyle.ui_scale
	PixelStyle.ui_scale = 1.0
	equal(PixelStyle.scaled(10), 10, "at 100% a size is itself")
	var base := PixelStyle.scaled_vec(Vector2(200.0, 34.0))
	PixelStyle.ui_scale = 1.5
	equal(PixelStyle.scaled(10), 15, "at 150% it is half again")
	equal(PixelStyle.scaled_vec(Vector2(200.0, 34.0)).x, base.x * 1.5, "and so is a button")
	PixelStyle.ui_scale = 0.5
	equal(PixelStyle.scaled(4), 6, "and a nonsense-small size still lands on a real font size")
	PixelStyle.ui_scale = kept


func _test_cycling_wraps() -> void:
	section("a cycle button steps and wraps")
	equal(GameSettings.next_index(0, 3), 1, "the next index")
	equal(GameSettings.next_index(2, 3), 0, "and past the end it wraps")
	equal(GameSettings.next_index(0, 0), 0, "an empty table is index zero, not a crash")


func _test_scale_commit_announces() -> void:
	section("committing a scale change tells the built screens to rebuild")
	var kept_path := GameSettings.path
	GameSettings.path = TEST_PATH
	var seen := [0]
	var probe := func() -> void: seen[0] += 1
	GameSettings.ui_scale_committed.connect(probe)
	var kept_scale := GameSettings.ui_scale
	GameSettings.ui_scale = 1.1
	GameSettings.commit_ui_scale()
	GameSettings.ui_scale_committed.disconnect(probe)
	equal(seen[0], 1, "one commit, one announcement")
	GameSettings.ui_scale = kept_scale
	GameSettings.path = kept_path
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))


func _test_save_and_load_round_trip() -> void:
	section("choices survive a save and a load")
	# The suite writes to its own file and puts the player's settings back, the same courtesy the
	# save suites show the save directory. apply() is never called: a test must not resize the
	# window of the machine it runs on.
	var kept_path := GameSettings.path
	var kept_window := GameSettings.window_index
	var kept_vsync := GameSettings.vsync_index
	var kept_fps := GameSettings.fps_index
	var kept_scale := PixelStyle.ui_scale

	GameSettings.path = TEST_PATH
	GameSettings.window_index = 0
	GameSettings.window_size_index = 1
	GameSettings.ui_scale = 1.25
	GameSettings.vsync_index = 0
	GameSettings.fps_index = 2
	GameSettings.show_perf_overlay = true
	GameSettings.show_hints = false
	GameSettings.save_settings()

	GameSettings.window_index = 1
	GameSettings.window_size_index = 3
	GameSettings.ui_scale = 1.0
	GameSettings.vsync_index = 1
	GameSettings.fps_index = 5
	GameSettings.show_perf_overlay = false
	GameSettings.show_hints = true
	check(GameSettings.load_settings(false), "the file is there to read")
	equal(GameSettings.window_index, 0, "the window choice came back")
	equal(GameSettings.window_size_index, 1, "and the window size")
	equal(GameSettings.ui_scale, 1.25, "and the UI scale")
	equal(GameSettings.vsync_index, 0, "and the vsync choice")
	equal(GameSettings.fps_index, 2, "and the frame cap")
	equal(GameSettings.show_perf_overlay, true, "and the overlay choice")
	equal(GameSettings.show_hints, false, "and the hints choice")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))
	GameSettings.path = kept_path
	GameSettings.window_index = kept_window
	GameSettings.vsync_index = kept_vsync
	GameSettings.fps_index = kept_fps
	PixelStyle.ui_scale = kept_scale
