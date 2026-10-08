extends TestCase
## B2a: the unit dock is a pure presentation boundary. It never mutates battle state.


func run() -> void:
	await _tick()
	_test_full_snapshot_and_casualties()
	_test_selection_requests_and_replacement()
	_test_destroyed_and_missing_formations()
	_test_portrait_fallback_and_type_change()
	_test_ordering_and_duplicate_ids()
	_complete()


static func _body(id: int, side: int = 0, alive: int = 20, started: int = 20,
		name: String = "Spearmen", unit_key: String = "spearman") -> Dictionary:
	return {"id": id, "side": side, "alive": alive, "started": started,
		"name": name, "type_key": unit_key, "shape": "line", "order": "HOLD"}


func _test_full_snapshot_and_casualties() -> void:
	section("only friendly formations appear, with accurate strength and order")
	var dock := BattleUnitDock.new()
	runner.add_child(dock)
	var bodies: Array[Dictionary] = [
		_body(1, 0, 32, 40),
		_body(99, 1, 18, 20, "Enemy"),
		_body(-1, 0, 5, 5, "Invalid"),
		_body(2, 0, 5, 20, "Archers", "archer"),
	]
	dock.update_bodies(bodies, [1])
	equal(dock._cards.size(), 2, "enemy and invalid IDs never create roster cards")
	equal(dock._row.get_child_count(), 2, "two friendly cards are visible")
	check(dock._cards.has(1), "the first friendly formation is present")
	check(dock._cards.has(2), "the second friendly formation is present")
	var first: Dictionary = dock._cards[1]
	equal((first["title"] as Label).text, "Spearmen", "formation name is displayed")
	equal((first["count"] as Label).text, "32 / 40", "casualties are displayed as survivors / starting strength")
	equal((first["shape"] as Label).text, "LINE · HOLD", "formation and order are displayed")
	approx((first["strength"] as ProgressBar).value, 80.0, 0.01, "strength strip uses surviving fraction")
	check((first["button"] as Button).button_pressed, "selected friendly formation is highlighted")
	var second: Dictionary = dock._cards[2]
	approx((second["strength"] as ProgressBar).value, 25.0, 0.01, "depleted formation has 25 percent strength")
	check(not (second["button"] as Button).button_pressed, "unselected formation is not highlighted")
	var updated: Array[Dictionary] = [_body(1, 0, 12, 40)]
	dock.update_bodies(updated, [])
	equal((dock._cards[1]["count"] as Label).text, "12 / 40", "casualty update changes the displayed count")
	approx((dock._cards[1]["strength"] as ProgressBar).value, 30.0, 0.01, "casualty update changes the strength strip")
	check((dock._cards[1]["button"] as Button) == (first["button"] as Button),
		"a same-type update reuses the card instead of rebuilding the row")
	check(not (dock._cards[1]["button"] as Button).button_pressed, "caller clears selection")
	equal(dock._cards.size(), 1, "missing formation is removed on replacement snapshot")
	dock.free()


func _test_selection_requests_and_replacement() -> void:
	section("single and additive selection are requests, not local simulation changes")
	var dock := BattleUnitDock.new()
	runner.add_child(dock)
	var bodies: Array[Dictionary] = [_body(1), _body(2)]
	dock.update_bodies(bodies, [1])
	var events: Array[Dictionary] = []
	dock.body_chosen.connect(func(id: int, additive: bool):
		events.append({"id": id, "additive": additive}))
	dock.request_selection(2, false)
	dock.request_selection(1, true)
	equal(events.size(), 2, "one request emitted per user action")
	equal(events[0]["id"], 2, "replacement selection carries the clicked ID")
	equal(events[0]["additive"], false, "replacement selection is not additive")
	equal(events[1]["id"], 1, "additive selection carries the clicked ID")
	equal(events[1]["additive"], true, "additive selection flag survives")
	(dock._cards[2]["button"] as Button).pressed.emit()
	equal(events.size(), 3, "clicking a real card button forwards one selection event")
	equal(events[2]["id"], 2, "button event carries its own formation ID")
	equal(events[2]["additive"], Input.is_key_pressed(KEY_SHIFT),
		"button event uses the current Shift modifier")
	check((dock._cards[1]["button"] as Button).button_pressed,
		"emitting a request does not mutate the caller's current selection")
	check(not (dock._cards[2]["button"] as Button).button_pressed,
		"request does not locally select the clicked formation")
	dock.update_bodies(bodies, [2])
	check(not (dock._cards[1]["button"] as Button).button_pressed,
		"caller can replace selection on next snapshot")
	check((dock._cards[2]["button"] as Button).button_pressed,
		"caller-provided replacement selection is displayed")
	dock.update_bodies(bodies, [1, 2])
	check((dock._cards[1]["button"] as Button).button_pressed,
		"caller can display the first member of additive selection")
	check((dock._cards[2]["button"] as Button).button_pressed,
		"caller can display the second member of additive selection")
	dock.free()


func _test_destroyed_and_missing_formations() -> void:
	section("dead bodies remain visible but unselectable until the snapshot removes them")
	var dock := BattleUnitDock.new()
	runner.add_child(dock)
	var dead: Array[Dictionary] = [_body(7, 0, 0, 20, "Fallen")]
	dock.update_bodies(dead, [7])
	check(dock._cards.has(7), "destroyed formation remains visible while reported")
	equal((dock._cards[7]["count"] as Label).text, "0 / 20", "destroyed formation shows zero survivors")
	approx((dock._cards[7]["strength"] as ProgressBar).value, 0.0, 0.01,
		"destroyed formation has zero strength")
	check((dock._cards[7]["button"] as Button).disabled, "destroyed formation cannot be selected")
	check(not (dock._cards[7]["button"] as Button).button_pressed,
		"dead formation cannot remain highlighted")
	var events: Array[int] = []
	dock.body_chosen.connect(func(id: int, _additive: bool): events.append(id))
	dock.request_selection(7, false)
	dock.request_selection(999, true)
	(dock._cards[7]["button"] as Button).pressed.emit()
	equal(events.size(), 0, "dead and unknown IDs emit no selection events, even via the button")
	var empty: Array[Dictionary] = []
	dock.update_bodies(empty, [])
	equal(dock._cards.size(), 0, "removed formations are forgotten")
	equal(dock._row.get_child_count(), 0, "removed formations leave no stale UI cards")
	dock.request_selection(7, false)
	equal(events.size(), 0, "a removed ID cannot emit selection")
	dock.free()


func _test_portrait_fallback_and_type_change() -> void:
	section("missing atlas is an explicit neutral sign, not a fake portrait")
	var dock := BattleUnitDock.new()
	runner.add_child(dock)
	dock._art = null
	var placeholder := dock._portrait("spearman")
	equal(placeholder.get_child_count(), 1, "missing art creates one fallback element")
	check(placeholder.get_child(0) is Label, "fallback is a neutral class sign")
	placeholder.free()
	var bodies: Array[Dictionary] = [_body(1, 0, 10, 10, "Vanguard", "spearman")]
	dock.update_bodies(bodies, [])
	var old_button: Button = dock._cards[1]["button"]
	equal(str(dock._cards[1]["unit_key"]), "spearman", "card records portrait identity")
	bodies[0]["type_key"] = "archer"
	dock.update_bodies(bodies, [])
	equal(str(dock._cards[1]["unit_key"]), "archer", "portrait identity updates with unit type")
	check(dock._cards[1]["button"] != old_button,
		"changing unit type rebuilds the portrait card instead of leaving stale art")
	equal(dock._cards.size(), 1, "portrait replacement never duplicates a card")
	dock.free()


func _test_ordering_and_duplicate_ids() -> void:
	section("snapshot order is authoritative and duplicate IDs cannot create extra cards")
	var dock := BattleUnitDock.new()
	runner.add_child(dock)
	var bodies: Array[Dictionary] = [_body(1), _body(2)]
	dock.update_bodies(bodies, [])
	equal(dock._row.get_child(0), dock._cards[1]["button"], "initial roster order follows snapshot")
	var reordered: Array[Dictionary] = [_body(2), _body(1), _body(2)]
	dock.update_bodies(reordered, [])
	equal(dock._cards.size(), 2, "duplicate ID does not create duplicate cards")
	equal(dock._row.get_child_count(), 2, "duplicate ID does not create duplicate UI children")
	equal(dock._row.get_child(0), dock._cards[2]["button"], "first card follows updated snapshot order")
	equal(dock._row.get_child(1), dock._cards[1]["button"], "second card follows updated snapshot order")
	dock.free()
