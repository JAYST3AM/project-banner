extends TestCase
## The battle command bar is presentation-only: actions are emitted, not applied.


func run() -> void:
	await _tick()
	_test_actions_are_forwarded_without_simulation()
	_test_status_and_selection_labels()
	_test_every_visible_button_emits_its_own_action()
	_test_stage_transition_and_label_reset()
	_test_pre_ready_status_is_safe()
	_complete()


func _test_actions_are_forwarded_without_simulation() -> void:
	section("command bar forwards user actions without modifying battle state")
	var bar := BattleCommandBar.new()
	runner.add_child(bar)
	var actions: Array[String] = []
	bar.action_requested.connect(func(action: String): actions.append(action))
	bar._invoke("hold")
	equal(actions.size(), 1, "a command emits exactly one action")
	if actions.size() == 1:
		equal(actions[0], "hold", "the action name is preserved")
	var hold_button: Button = null
	for child in bar.find_children("*", "Button", true, false):
		var button := child as Button
		if button != null and button.text.contains("H  HOLD"):
			hold_button = button
			break
	check(hold_button != null, "hold control exists in the command strip")
	if hold_button != null:
		hold_button.pressed.emit()
		equal(actions.size(), 2, "pressing the control emits one action")
		if actions.size() == 2:
			equal(actions[1], "hold", "the button routes to hold")
	bar.free()


func _test_status_and_selection_labels() -> void:
	section("command bar reflects the caller's state without owning it")
	var bar := BattleCommandBar.new()
	runner.add_child(bar)
	bar.set_battle_status(true, 12, 8, 2, false, false)
	equal(bar._stage.text, "DEPLOYMENT", "deployment state is visible")
	contains(bar._forces.text, "12", "friendly strength is displayed")
	contains(bar._forces.text, "8", "enemy strength is displayed")
	equal(bar._selection.text, "2 FORMATIONS SELECTED", "multiple selection is clear")
	bar.set_battle_status(false, 9, 7, 1, true, true)
	equal(bar._stage.text, "BATTLE PAUSED", "paused state is visible")
	equal(bar._selection.text, "1 FORMATION SELECTED", "singular selection is clear")
	equal(bar._map_button.text, "T  RETURN", "overview toggle reflects its state")
	equal(bar._pause_button.text, "P  RESUME", "pause toggle reflects its state")
	bar.set_battle_status(false, 9, 7, 0, false, false)
	equal(bar._stage.text, "IN BATTLE", "active state is visible")
	equal(bar._selection.text, "SELECT A FORMATION", "empty selection is visible")
	bar.free()


## PB-202: test the seven REAL controls, not just _invoke("hold").
## The action array is checked by index so a duplicated/miswired action cannot
## pass merely because seven signals were emitted.
func _test_every_visible_button_emits_its_own_action() -> void:
	section("all seven command controls forward exactly their own action")
	var bar := BattleCommandBar.new()
	runner.add_child(bar)
	var expected: Array[String] = ["hold", "engage", "line", "column", "loose", "map", "pause"]
	var captions: Array[String] = [
		"H  HOLD", "U  ENGAGE", "L  LINE", "C  COLUMN",
		"O  LOOSE", "T  MAP", "P  PAUSE"]
	var controls := bar.find_children("*", "Button", true, false)
	equal(controls.size(), expected.size(), "exactly seven command controls are present")
	var actual: Array[String] = []
	bar.action_requested.connect(func(action: String): actual.append(action))
	for i in mini(controls.size(), expected.size()):
		var button := controls[i] as Button
		check(button != null, "control %d is a button" % i)
		if button == null:
			continue
		equal(button.text, captions[i], "control %d has the documented caption" % i)
		button.pressed.emit()
		equal(actual.size(), i + 1, "control %d emits exactly one action" % i)
		if actual.size() == i + 1:
			equal(actual[i], expected[i], "control %d forwards the correct action" % i)
	bar.free()


func _test_stage_transition_and_label_reset() -> void:
	section("deployment, active, paused and resumed transitions reset every label")
	var bar := BattleCommandBar.new()
	runner.add_child(bar)
	bar.set_battle_status(true, 40, 35, 0, false, false)
	equal(bar._stage.text, "DEPLOYMENT", "starts at deployment")
	equal(bar._forces.text, "OUR ARMY  40    /    ENEMY  35",
		"both initial forces are exact, not inferred")
	bar.set_battle_status(false, 39, 32, 3, true, false)
	equal(bar._stage.text, "IN BATTLE", "start transitions to live battle")
	equal(bar._selection.text, "3 FORMATIONS SELECTED", "three selected formations are counted")
	equal(bar._map_button.text, "T  RETURN", "map action says return in map mode")
	equal(bar._pause_button.text, "P  PAUSE", "unpaused battle offers pause")
	bar.set_battle_status(false, 31, 18, 1, true, true)
	equal(bar._stage.text, "BATTLE PAUSED", "pause transitions to paused")
	equal(bar._forces.text, "OUR ARMY  31    /    ENEMY  18",
		"casualties update while paused")
	equal(bar._selection.text, "1 FORMATION SELECTED", "singular count uses singular label")
	equal(bar._pause_button.text, "P  RESUME", "pause control offers resume")
	bar.set_battle_status(false, 30, 17, 0, false, false)
	equal(bar._stage.text, "IN BATTLE", "resume restores live stage")
	equal(bar._selection.text, "SELECT A FORMATION", "clearing selection drops old count")
	equal(bar._map_button.text, "T  MAP", "closing overview restores map action")
	equal(bar._pause_button.text, "P  PAUSE", "resuming restores pause action")
	bar.free()


func _test_pre_ready_status_is_safe() -> void:
	section("pre-ready status is replayed, with only the latest caller snapshot kept")
	var bar := BattleCommandBar.new()
	var emitted: Array[String] = []
	bar.action_requested.connect(func(action: String): emitted.append(action))
	bar.set_battle_status(false, 1, 2, 1, false, false)
	bar.set_battle_status(false, 5, 7, 2, true, true)
	check(bar._stage == null, "pre-ready updates do not fabricate half-built UI")
	runner.add_child(bar)
	check(bar._stage != null, "ready builds the command strip normally")
	if bar._stage != null:
		equal(bar._stage.text, "BATTLE PAUSED", "latest queued stage applies when ready")
		equal(bar._forces.text, "OUR ARMY  5    /    ENEMY  7",
			"latest queued troop counts replace the earlier ones")
		equal(bar._selection.text, "2 FORMATIONS SELECTED",
			"latest queued selection count is retained")
		equal(bar._map_button.text, "T  RETURN", "queued map mode is retained")
		equal(bar._pause_button.text, "P  RESUME", "queued pause state is retained")
	equal(emitted.size(), 0, "replaying a status snapshot never emits a command")
	bar.free()
