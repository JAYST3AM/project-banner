extends TestCase
## Tactical map's unit-strength visuals must reflect actual surviving men.


func run() -> void:
	await _tick()
	_test_strength_from_roster()
	_test_invalid_strength_values()
	_complete()


func _test_strength_from_roster() -> void:
	section("formation map strength strips show actual losses")
	equal(BattleTacticalOverview.strength_fraction(40, 40), 1.0,
		"an intact formation has a complete strip")
	equal(BattleTacticalOverview.strength_fraction(20, 40), 0.5,
		"half of the original troops means half the strip")
	equal(BattleTacticalOverview.strength_fraction(0, 40), 0.0,
		"a destroyed body has no strength")


func _test_invalid_strength_values() -> void:
	section("strength indicators stay within valid bounds")
	equal(BattleTacticalOverview.strength_fraction(-1, 40), 0.0,
		"negative troop counts never draw negative widths")
	equal(BattleTacticalOverview.strength_fraction(55, 40), 1.0,
		"survivors above the starting count never overflow the frame")
	equal(BattleTacticalOverview.strength_fraction(0, 0), 0.0,
		"zero-sized bodies never divide by zero")
