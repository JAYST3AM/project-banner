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

## The per-suite stall marker, checked in [method _process]. It catches a suite that goes quiet
## WHILE YIELDING. It cannot catch one that blocks the main thread, because _process does not run
## while a synchronous suite hogs the frame. Measured 2026-10-09: test_battle_hardening (~207 s) and
## test_formation_engagement (~146 s) are legitimately long, not stuck, and both are purely
## synchronous (0 awaits inside run()). So this marker does NOT mean "over 90 s is stuck" - it means
## "a suite that yields and then goes quiet for 90 s is stuck".
const SUITE_DEADLINE_S := 90

## The bound the EXTERNAL VERIFIER enforces, per suite and on the child process
## (project-banner-mcp/tools/verify_branch.py). It kills the process TREE on expiry and fails the gate
## whatever this process manages to print, because a forced kill can lose buffered output. 900 s is a
## safety ceiling, not a performance target: it sits far above the slowest measured suite (~207 s) so it
## only ever means "this run is not coming back".
##
## This constant also arms the in-process thread below, which is DIAGNOSTICS ONLY - it names the suite and
## kills the process so that a DIRECT multi-suite run, with no verifier around it, cannot hang forever. It
## is not the thing that makes a failed run fail.
const HARD_DEADLINE_S := 900

const SUITES: Array[String] = [
	"res://tests/test_core_services.gd",
	"res://tests/test_campaign_flow.gd",
	"res://tests/test_banner.gd",
	"res://tests/test_world_map.gd",
	"res://tests/test_world_chunks.gd",
	"res://tests/test_world_sites.gd",
	"res://tests/test_settlement_details.gd",
	"res://tests/test_settlement_buildings.gd",
	"res://tests/test_trade_caravans.gd",
	"res://tests/test_sprite_list.gd",
	"res://tests/test_settings.gd",
	"res://tests/test_roads.gd",
	"res://tests/test_recruitment.gd",
	"res://tests/test_party_semantics.gd",
	"res://tests/test_encounters.gd",
	"res://tests/test_combat.gd",
	"res://tests/test_battle_outcomes.gd",
	"res://tests/test_terrain.gd",
	"res://tests/test_formation.gd",
	"res://tests/test_formation_battle.gd",
	"res://tests/test_battle_view.gd",
	"res://tests/test_battle_formation_navigator.gd",
	"res://tests/test_battle_formation_cohesion.gd",
	"res://tests/test_battle_placement.gd",
	"res://tests/test_battle_command_bar.gd",
	"res://tests/test_battle_deployment_overlay.gd",
	"res://tests/test_battle_tactical_overview.gd",
	"res://tests/test_spatial_grid.gd",
	"res://tests/test_overlap.gd",
	"res://tests/test_overlap_oracle.gd",
	"res://tests/test_target_acquisition.gd",
	"res://tests/test_formation_focus.gd",
	"res://tests/test_target_search.gd",
	"res://tests/test_native_query.gd",
	"res://tests/test_battle_hardening.gd",
	"res://tests/test_formation_engagement.gd",
	"res://tests/test_soldier_batch.gd",
	"res://tests/test_battle_arrows.gd",
	"res://tests/test_unit_sprites.gd",
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
## The wall-clock the current suite must finish by, and its name for the report. Empty name means no
## suite is running. Checked in [method _process], which runs while the tree is paused.
var _deadline_ms: int = 0
var _stuck_suite: String = ""
## Set once the run has ended, so the hard-deadline thread can retire quietly.
var _run_finished: bool = false
var _hard_deadline_thread: Thread = null
## Guards every variable the deadline thread shares with the main thread (GPT-6 review, TI-2).
var _mutex := Mutex.new()
## When the suite currently in flight started, so the bound re-arms per suite instead of counting
## from process start. Zero means "between suites" - nothing to bound.
var _suite_started_ms: int = 0


## A bound that survives a blocked main thread: the thread only sleeps, checks one flag and - if the
## run is genuinely not coming back - names the suite and kills the process. It never touches the
## scene tree, so it is safe off the main thread. See TI-2 in docs/TEST-INTEGRITY-FINDINGS.md.
## Diagnostics only, and deliberately not the mechanism that guarantees a failed run. The external
## verifier (project-banner-mcp/tools/verify_branch.py) owns the authoritative per-suite bound: it owns
## the child process, terminates it and fails the gate independently of anything printed here - a forced
## kill can lose buffered output, so nothing in this process may be the only safeguard.
## This thread exists so that a DIRECT multi-suite run (no verifier around it) still cannot hang forever,
## which is why it re-arms per suite rather than counting from process start.
func _hard_deadline_watch() -> void:
	while true:
		OS.delay_msec(500)
		_mutex.lock()
		var finished := _run_finished
		var started_ms := _suite_started_ms
		var in_flight := _stuck_suite
		_mutex.unlock()
		if finished:
			return
		if started_ms > 0 and Time.get_ticks_msec() - started_ms > HARD_DEADLINE_S * 1000:
			print("")
			print("  !! HARD DEADLINE: the suite in flight has not finished after %d seconds" % HARD_DEADLINE_S)
			print("  !! in flight: %s" % ("(between suites)" if in_flight.is_empty() else in_flight))
			print("  !! a synchronous suite cannot be interrupted from GDScript, so the process is killed")
			print("  !! rather than left running - the verifier's own timeout is what fails the gate")
			OS.kill(OS.get_process_id())


func _ready() -> void:
	_hard_deadline_thread = Thread.new()
	_hard_deadline_thread.start(_hard_deadline_watch)
	# The runner has to keep running while the game is paused: a suite that pauses the tree must not
	# be able to take the watchdog down with it.
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Suites wipe their saves at the start and end of every fixture. Point that at a test directory
	# so a run can never eat the campaign somebody is partway through. See save_manager.save_dir().
	OS.set_environment("PB_TEST_SAVES", "1")
	SceneManager.adopt_initial_scene(true)
	# The suites assert about a known map - Greywatch, four settlements, four roads - and the game
	# generates its world now, so they run against the authored one. The generator has its own suite
	# and does not need every other suite to be rewritten around it: a fixture is a fixture.
	GameManager.config().set_value("world.procedural", false)
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
	_mutex.lock()
	_run_finished = true
	_mutex.unlock()
	if _hard_deadline_thread != null:
		_hard_deadline_thread.wait_to_finish()
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


## Runs even when the tree is paused, which is the whole point: the pause that a stuck suite leaves
## behind would otherwise also silence the thing that reports it.
func _process(_delta: float) -> void:
	if _stuck_suite.is_empty() or Time.get_ticks_msec() < _deadline_ms:
		return
	_on_suite_deadline(_stuck_suite)


## The watchdog fired: say which suite, say what it means, and end the process with a code that is
## not a pass. Rerunning the named suite alone will show it green, which is the signature of state
## left behind by whatever ran before it.
func _on_suite_deadline(suite_name: String) -> void:
	print("")
	print("  !! suite '%s' is stuck: still running after %d seconds" % [suite_name, SUITE_DEADLINE_S])
	print("  !! it passes alone, if it passes alone, so look at what the suites before it leave behind")
	print("  !! ending the run here rather than pretending it was slow")
	get_tree().quit(2)


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

	# The pause is cleared before every suite. A suite that opens the pause menu and does not close it
	# leaves the whole tree frozen, and the next suite's awaits then never complete - which is what
	# stalled this run for fifteen minutes twice, and, because the first version of this watchdog was
	# a SceneTreeTimer, froze the watchdog too.
	get_tree().paused = false
	# A watchdog by the clock, checked in _process: a suite cannot be interrupted - GDScript has no
	# way to cancel a coroutine awaiting something that will never arrive - but the run does not have
	# to be silent about it. Nineteen times the honest cost of a suite, so only a stuck one reaches it.
	_mutex.lock()
	_deadline_ms = Time.get_ticks_msec() + SUITE_DEADLINE_S * 1000
	_stuck_suite = suite.suite_name
	_suite_started_ms = Time.get_ticks_msec()
	_mutex.unlock()
	await suite.run()
	_mutex.lock()
	_stuck_suite = ""
	_suite_started_ms = 0
	_mutex.unlock()

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
