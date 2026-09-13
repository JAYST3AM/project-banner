extends Node
## Headless test runner.
##
## Usage:
## [codeblock]
## godotc --headless --path "<project>" res://scenes/dev/tests.tscn
## # or a single suite by name:
## godotc --headless --path "<project>" res://scenes/dev/tests.tscn -- --suite=campaign
## [/codeblock]
##
## Exit code 0 = every suite passed, 1 = at least one failure. That exit code is
## what the milestone workflow gates on.

const SUITES: Array[String] = [
	"res://tests/test_core_services.gd",
	"res://tests/test_campaign_flow.gd",
]

var _failures: int = 0
var _checks: int = 0


func _ready() -> void:
	SceneManager.adopt_initial_scene()
	await get_tree().process_frame
	await _run_all()
	var failed := _failures > 0
	print("")
	print("================ TEST SUMMARY ================")
	print("  suites: %d   assertions: %d   failures: %d" % [
		_selected_suites().size(), _checks, _failures,
	])
	print("  RESULT: %s" % ("FAIL" if failed else "PASS"))
	print("=============================================")
	get_tree().quit(1 if failed else 0)


func _selected_suites() -> Array[String]:
	var filter := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--suite="):
			filter = arg.trim_prefix("--suite=").to_lower()
	if filter.is_empty():
		return SUITES
	var selected: Array[String] = []
	for path in SUITES:
		if path.get_file().to_lower().contains(filter):
			selected.append(path)
	return selected


func _run_all() -> void:
	print("")
	print("############ PROJECT BANNER TEST RUN ############")
	for path in _selected_suites():
		await _run_suite(path)


func _run_suite(path: String) -> void:
	var script: Variant = load(path)
	if script == null:
		_failures += 1
		print("  [load] FAILED to load %s" % path)
		return
	var suite: TestCase = script.new()
	if suite == null:
		_failures += 1
		print("  [build] FAILED to instantiate %s" % path)
		return
	suite.runner = self
	suite.suite_name = path.get_file().get_basename()
	print("")
	print("== %s ==" % suite.suite_name)
	var started := Time.get_ticks_msec()
	await suite.run()
	var elapsed := Time.get_ticks_msec() - started
	_checks += suite.checks
	_failures += suite.failures.size()
	print("   %s  (%d assertions, %d failures, %d ms)" % [
		"PASS" if suite.passed() else "FAIL", suite.checks, suite.failures.size(), elapsed,
	])
