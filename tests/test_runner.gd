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
## Guarding philosophy: a suite that cannot load, cannot be constructed, runs zero
## assertions, or does not reach its completion marker is a FAILURE. GDScript aborts
## a function on a runtime error and has no try/catch, and - verified against Godot
## 4.7.2, not assumed - control [i]does[/i] return to the caller when that happens.
## A suite that raised an error part-way through therefore comes back looking
## perfectly healthy: it reports "3 assertions, 0 failures". Only the completion
## marker distinguishes "finished cleanly" from "died in the middle", which is why
## every suite must end with [method TestCase._complete].

const PASS := "pass"
const FAIL := "fail"
const BROKEN := "broken"

const SUITES: Array[String] = [
	"res://tests/test_core_services.gd",
	"res://tests/test_campaign_flow.gd",
	"res://tests/test_world_map.gd",
	"res://tests/test_recruitment.gd",
	"res://tests/test_party_semantics.gd",
	"res://tests/test_encounters.gd",
	"res://tests/test_combat.gd",
	"res://tests/test_battle_outcomes.gd",
	"res://tests/test_terrain.gd",
	"res://tests/test_formation.gd",
	"res://tests/test_formation_battle.gd",
	"res://tests/test_spatial_grid.gd",
	"res://tests/test_overlap.gd",
	"res://tests/test_target_acquisition.gd",
	"res://tests/test_formation_focus.gd",
	"res://tests/test_enemy_persistence.gd",
	"res://tests/test_e2e_loop.gd",
	"res://tests/test_persistence.gd",
	"res://tests/test_legacy_menu.gd",
	"res://tests/test_runner_contract.gd",
]

var _failures: int = 0
var _checks: int = 0
var _suites_reported: int = 0
var _suites_expected: int = 0
var _suites_broken: int = 0


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
	if _suites_broken > 0:
		print("  %d suite(s) were BROKEN - they did not run to completion" % _suites_broken)
	print("  RESULT: %s" % ("FAIL" if failed else "PASS"))
	print("=============================================")
	get_tree().quit(1 if failed else 0)


## The value of a --suite= argument, lowercased, or "" when none was given.
func _suite_filter() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--suite="):
			return arg.trim_prefix("--suite=").to_lower()
	return ""


func _selected_suites() -> Array[String]:
	return select_suites(_suite_filter())


## Suites matching a filter string. Pure and static so the self-tests can check the
## matching rules directly, without having to fake command-line arguments.
##
## An empty filter means "all suites". A filter that matches nothing means "none",
## which [method _run_all] treats as a failure rather than a vacuous pass.
static func select_suites(filter: String) -> Array[String]:
	if filter.strip_edges().is_empty():
		return SUITES
	var needle := filter.to_lower()
	var selected: Array[String] = []
	for path in SUITES:
		if path.get_file().to_lower().contains(needle):
			selected.append(path)
	return selected


func _run_all() -> void:
	var suites := _selected_suites()
	_suites_expected = suites.size()
	print("")
	print("############ PROJECT BANNER TEST RUN ############")
	var filter := _suite_filter()
	if not filter.is_empty():
		print("  filter: --suite=%s" % filter)

	if suites.is_empty():
		# A filter that matches nothing selects nothing to run, so every count below
		# is zero and the run looks immaculate. It is not a pass - it is a typo that
		# would silently disable the gate.
		_failures += 1
		print("")
		print("  !! no suite matched --suite=%s" % filter)
		print("     available suites: %s" % ", ".join(_suite_names()))
		return

	for path in suites:
		await _run_suite(path)

	# A suite that died before reporting is a failure, even if it never got the
	# chance to record one.
	if _suites_reported < _suites_expected:
		var missing := _suites_expected - _suites_reported
		_failures += missing
		print("")
		print("  !! %d of %d suites never reported a result" % [missing, _suites_expected])


func _suite_names() -> Array[String]:
	var names: Array[String] = []
	for path in SUITES:
		names.append(path.get_file().get_basename())
	return names


## Run one suite in isolation and classify the outcome.
##
## Separated from [method _run_suite] so the self-tests can drive this exact logic
## against deliberately malformed fixtures. Returns:
## [code]{"status": "pass"|"fail"|"broken", "checks": int, "failures": int, "reason": String}[/code]
func evaluate(path: String) -> Dictionary:
	var loaded: Variant = load(path)
	if loaded == null or not (loaded is GDScript):
		return _broken("could not be loaded")
	var script := loaded as GDScript
	if not script.can_instantiate():
		return _broken("failed to compile (see parse errors above)")

	var built: Variant = script.new()
	if built == null or not (built is TestCase):
		return _broken("did not produce a TestCase")
	var suite := built as TestCase
	suite.runner = self
	suite.suite_name = path.get_file().get_basename()

	await suite.run()

	# Order matters. A suite that aborted mid-run still carries whatever assertions
	# it got through, and those all passed - checking failure count first would call
	# it healthy. The completion marker is the only trustworthy signal.
	if not suite.completed:
		return {
			"status": BROKEN,
			"checks": suite.checks,
			"failures": maxi(1, suite.failures.size()),
			## What the suite itself recorded before classification. For an aborted
			## suite this is normally 0, which is exactly why the marker is needed.
			"raw_failures": suite.failures.size(),
			"reason": "did not run to completion (runtime error part-way through run())",
		}
	if suite.checks == 0:
		return {
			"status": BROKEN,
			"checks": 0,
			"failures": maxi(1, suite.failures.size()),
			"raw_failures": suite.failures.size(),
			"reason": "ran no assertions",
		}
	return {
		"status": PASS if suite.passed() else FAIL,
		"checks": suite.checks,
		"failures": suite.failures.size(),
		"raw_failures": suite.failures.size(),
		"reason": "",
	}


func _broken(reason: String) -> Dictionary:
	return {"status": BROKEN, "checks": 0, "failures": 1, "raw_failures": 0, "reason": reason}


func _run_suite(path: String) -> void:
	print("")
	print("== %s ==" % path.get_file().get_basename())

	var started := Time.get_ticks_msec()
	var outcome := await evaluate(path)
	var elapsed := Time.get_ticks_msec() - started

	_checks += int(outcome.get("checks", 0))
	_failures += int(outcome.get("failures", 0))
	_suites_reported += 1
	var status := str(outcome.get("status", BROKEN))
	if status == BROKEN:
		_suites_broken += 1

	var reason := str(outcome.get("reason", ""))
	print("   %s  (%d assertions, %d failures, %d ms)%s" % [
		status.to_upper(), int(outcome.get("checks", 0)), int(outcome.get("failures", 0)),
		elapsed, "" if reason.is_empty() else "  - %s" % reason,
	])
