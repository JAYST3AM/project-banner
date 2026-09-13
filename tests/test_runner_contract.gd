extends TestCase
## Self-tests for the test runner itself.
##
## These drive the runner's own evaluate() against deliberately malformed fixtures,
## which is the only way to show that a broken suite is reported as broken rather
## than quietly passing. The fixtures live in tests/fixtures/ and are NOT in the
## runner's SUITES list - several of them are meant to fail, so adding them would
## simply break the build.
##
## One fixture raises a genuine runtime error, which prints a SCRIPT ERROR line.
## That is the point of it: the error is deliberate and provoked, and the assertions
## below prove it was detected. See the banner printed before that section.

const PASSING := "res://tests/fixtures/passing_suite.gd"
const FAILING := "res://tests/fixtures/failing_suite.gd"
const EMPTY := "res://tests/fixtures/empty_suite.gd"
const SILENT_RETURN := "res://tests/fixtures/silent_return_suite.gd"
const ABORTING := "res://tests/fixtures/aborting_suite.gd"
const NOT_A_SUITE := "res://tests/fixtures/not_a_test_case.gd"
const MISSING := "res://tests/fixtures/this_file_does_not_exist.gd"


func run() -> void:
	await _tick()

	await _test_healthy_suites()
	await _test_degenerate_suites()
	await _test_abort_detection()
	_test_filter_selection()

	_complete()


## A suite that finishes cleanly must pass; one that finishes with a real failed
## assertion must fail - and must NOT be confused with a broken suite, because they
## mean different things: "your code is wrong" vs "your test never ran".
func _test_healthy_suites() -> void:
	section("a suite that completes with passing assertions")
	var passing: Dictionary = await runner.evaluate(PASSING)
	equal(passing.get("status"), "pass", "a clean suite is classified as passing")
	equal(passing.get("failures"), 0, "a clean suite reports no failures")
	greater(passing.get("checks"), 0, "a clean suite reports the assertions it ran")
	equal(passing.get("reason"), "", "a clean suite reports no problem")

	section("a suite that completes with a failed assertion")
	var failing: Dictionary = await runner.evaluate(FAILING)
	equal(failing.get("status"), "fail", "a suite with a failed assertion is a failure")
	greater(failing.get("failures"), 0, "the failed assertion is counted")
	greater(failing.get("checks"), 0, "its assertions are still reported")
	not_equal(failing.get("status"), "broken", "a real failure is not mislabelled as broken")


## Suites that cannot meaningfully run: no assertions, or not a suite at all.
func _test_degenerate_suites() -> void:
	section("a suite that asserts nothing")
	var empty: Dictionary = await runner.evaluate(EMPTY)
	equal(empty.get("status"), "broken", "a suite with zero assertions does not pass")
	greater(empty.get("failures"), 0, "zero assertions counts as a failure")
	contains(str(empty.get("reason")), "no assertions", "the reason names the problem")

	section("a script that is not a test suite")
	var not_a_suite: Dictionary = await runner.evaluate(NOT_A_SUITE)
	equal(not_a_suite.get("status"), "broken", "a non-suite script does not pass")
	contains(str(not_a_suite.get("reason")), "TestCase", "the reason says it was not a TestCase")

	section("a suite that does not exist")
	var missing: Dictionary = await runner.evaluate(MISSING)
	equal(missing.get("status"), "broken", "a missing suite file does not pass")
	contains(str(missing.get("reason")), "not be loaded", "the reason says it could not be loaded")


## The case that motivated the completion contract.
##
## Confirmed against Godot 4.7.2: when a coroutine raises a runtime error, control
## returns to the caller as if the function had simply ended. The assertions that ran
## all passed, so the suite comes back reporting "N assertions, 0 failures" - which a
## runner checking only the failure count would call a PASS. Only the completion
## marker reveals that it died in the middle.
func _test_abort_detection() -> void:
	section("a suite that returns early without completing")
	var silent: Dictionary = await runner.evaluate(SILENT_RETURN)
	equal(silent.get("status"), "broken", "an early return is detected as broken")
	contains(str(silent.get("reason")), "completion", "the reason names the missing completion")
	greater(silent.get("checks"), 0, "the assertions it did run are still reported")
	equal(silent.get("raw_failures"), 0, "and none of them failed - so failure count alone would have passed it")

	print("")
	print("    ---- EXPECTED: the next line is a deliberate, provoked runtime error ----")
	var aborting: Dictionary = await runner.evaluate(ABORTING)
	print("    ---- end of deliberate error ----")
	equal(aborting.get("status"), "broken", "a suite killed mid-run by a runtime error is broken")
	contains(str(aborting.get("reason")), "completion", "the reason names the missing completion")
	greater(aborting.get("checks"), 0, "it recorded assertions before dying")
	equal(aborting.get("raw_failures"), 0, "none of those failed - the completion marker is the only signal")
	greater(aborting.get("failures"), 0, "and it is nonetheless counted as a failure")


## The --suite= filter, which must never turn a typo into a green run.
func _test_filter_selection() -> void:
	section("--suite= filter selection")
	var all: Array[String] = runner.select_suites("")
	greater(all.size(), 0, "an empty filter selects every suite")
	equal(runner.select_suites("test_").size(), all.size(), "a broad filter still matches every suite")

	var one: Array[String] = runner.select_suites("combat")
	equal(one.size(), 1, "a matching filter narrows to the named suite")
	contains(str(one[0]), "test_combat", "and picks the right one")

	var none: Array[String] = runner.select_suites("this_does_not_exist")
	equal(none.size(), 0, "a filter matching nothing selects nothing")
	# _run_all() turns that empty selection into a hard failure. This suite can only
	# check the selection half of that contract, since _run_all() ends by quitting the
	# process - the end-to-end behaviour is verified by running the runner itself.
	equal(runner.select_suites("COMBAT").size(), 1, "the filter is case-insensitive")
