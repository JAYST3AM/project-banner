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
	_test_cycling_wraps()
	_test_save_and_load_round_trip()
	_complete()


func _test_option_tables_line_up() -> void:
	section("every option has a label and a value")
	equal(GameSettings.WINDOW_LABELS.size(), GameSettings.WINDOW_MODES.size(),
		"window labels and modes")
	equal(GameSettings.VSYNC_LABELS.size(), GameSettings.VSYNC_VALUES.size(),
		"vsync labels and values")
	equal(GameSettings.FPS_LABELS.size(), GameSettings.FPS_CAPS.size(),
		"frame cap labels and values")
	greater(GameSettings.WINDOW_LABELS.size(), 1, "and there is more than one window mode to choose")


func _test_cycling_wraps() -> void:
	section("a cycle button steps and wraps")
	equal(GameSettings.next_index(0, 3), 1, "the next index")
	equal(GameSettings.next_index(2, 3), 0, "and past the end it wraps")
	equal(GameSettings.next_index(0, 0), 0, "an empty table is index zero, not a crash")


func _test_save_and_load_round_trip() -> void:
	section("choices survive a save and a load")
	# The suite writes to its own file and puts the player's settings back, the same courtesy the
	# save suites show the save directory. apply() is never called: a test must not resize the
	# window of the machine it runs on.
	var kept_path := GameSettings.path
	var kept_window := GameSettings.window_index
	var kept_vsync := GameSettings.vsync_index
	var kept_fps := GameSettings.fps_index

	GameSettings.path = TEST_PATH
	GameSettings.window_index = 0
	GameSettings.vsync_index = 0
	GameSettings.fps_index = 2
	GameSettings.save_settings()

	GameSettings.window_index = 1
	GameSettings.vsync_index = 1
	GameSettings.fps_index = 5
	check(GameSettings.load_settings(false), "the file is there to read")
	equal(GameSettings.window_index, 0, "the window choice came back")
	equal(GameSettings.vsync_index, 0, "and the vsync choice")
	equal(GameSettings.fps_index, 2, "and the frame cap")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))
	GameSettings.path = kept_path
	GameSettings.window_index = kept_window
	GameSettings.vsync_index = kept_vsync
	GameSettings.fps_index = kept_fps
