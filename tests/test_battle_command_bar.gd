extends TestCase
## The battle command bar is presentation-only: actions are emitted, not applied.


func run() -> void:
	await _tick()
	_test_actions_are_forwarded_without_simulation()
	_test_status_and_selection_labels()
	_complete()


func _test_actions_are_forwarded_without_simulation() -> void:
	section("command bar forwards user actions without modifying battle state")
	var bar := BattleCommandBar.new()
	runner.add_child(bar)
	var actions: Array[String] = []
	bar.action_requested.connect(func(action: String) -> void:
		actions.append(action))
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
