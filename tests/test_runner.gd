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
##
## Guarding philosophy: a suite that cannot load, cannot be constructed, or runs
## zero assertions is a FAILURE. GDScript aborts a function on a runtime error and
## has no try/catch, so without those guards a broken suite would silently look
## like a pass - which is worse than no test at all.

const SUITES: Array[String] = [
	"res://tests/test_core_services.gd",
	"res://tests/test_campaign_flow.gd",
	"res://tests/test_world_map.gd",
	"res://tests/test_recruitment.gd",
]

var _failures: int = 0
var _checks: int = 0
var _suites_reported: int = 0
var _suites_expected: int = 0


func _ready() -> void:
	SceneManager.adopt_initial_scene()
	await get_tree().process_frame
	await _run_all()
	var failed := _failures > 0
	print("")
	print("================ TEST SUMMARY ================")
	print("  suites: %d of %d reported   assertions: %d   failures: %d" % [
		_suites_reported, _suites_expected, _checks, _failures,
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
	var suites := _selected_suites()
	_suites_expected = suites.size()
	print("")
	print("############ PROJECT BANNER TEST RUN ############")
	for path in suites:
		await _run_suite(path)
	# A suite that died before reporting is a failure, even if it never got the
	# chance to record one.
	if _suites_reported < _suites_expected:
		_failures += _suites_expected - _suites_reported
		print("")
		print("  !! %d of %d suites never reported a result" % [
			_suites_expected - _suites_reported, _suites_expected,
		])


func _run_suite(path: String) -> void:
	print("")
	print("== %s ==" % path.get_file().get_basename())

	var loaded: Variant = load(path)
	if loaded == null or not (loaded is GDScript):
		_report_broken(path, "could not be loaded")
		return
	var script := loaded as GDScript
	if not script.can_instantiate():
		_report_broken(path, "failed to compile (see parse errors above)")
		return

	var built: Variant = script.new()
	if built == null or not (built is TestCase):
		_report_broken(path, "did not produce a TestCase")
		return
	var suite := built as TestCase
	suite.runner = self
	suite.suite_name = path.get_file().get_basename()

	var started := Time.get_ticks_msec()
	await suite.run()
	var elapsed := Time.get_ticks_msec() - started

	_checks += suite.checks
	_failures += suite.failures.size()
	_suites_reported += 1

	if suite.checks == 0:
		_failures += 1
		print("   FAIL  (0 assertions ran - the suite aborted before its first check)")
		return
	print("   %s  (%d assertions, %d failures, %d ms)" % [
		"PASS" if suite.passed() else "FAIL", suite.checks, suite.failures.size(), elapsed,
	])


func _report_broken(path: String, reason: String) -> void:
	_failures += 1
	print("   FAIL  %s %s" % [path.get_file(), reason])
