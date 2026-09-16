extends TestCase
## The block view: the boxes a large battle is drawn as.
##
## [b]What this guards.[/b] The block view walks every soldier in the army to work out where each box
## stands, and that walk belongs to the tick, not to the frame. Measured on the twenty-thousand-soldier
## showcase, doing it per frame cost 26 to 28 ms a frame to draw two hundred rectangles, against half a
## millisecond for the ground alone - and cost the same whether it drew two hundred boxes or forty-two,
## which is what told the real story: the rectangles were never the cost. Done once a tick it costs the
## rectangles, and the same measurement reads 0.6 to 1.9 ms. These assertions pin the rule, the boxes'
## correctness, and the promise that a thinned rank shows as a smaller box. See D-117.

const TICK := 0.05
const SEED := 70707
const PER_SIDE := 12


func run() -> void:
	await _tick()
	_test_the_boxes_are_rebuilt_once_a_tick_and_not_once_a_frame()
	_test_every_living_soldier_stands_inside_his_side_s_boxes()
	_test_a_thinned_rank_shows_as_a_smaller_box()
	_complete()


## A small production battle and an unparented view over it. The view is deliberately not added to
## the tree: it draws nothing here, so every rebuild counted below is one this suite asked for. The
## battle is started, because a step on an unstarted battle is a no-op and would leave the tick
## standing still - which is exactly what the first version of this fixture demonstrated.
func _showcase() -> Dictionary:
	var built := ShowcaseBattle.build(
		GameManager.config(), UnitCatalog.load_from(), FormationCatalog.load_from(), PER_SIDE, SEED)
	var view := BattleView.new()
	view.bind(built["simulator"], built["context"])
	built["simulator"].start()
	return {"simulator": built["simulator"], "view": view}


func _test_the_boxes_are_rebuilt_once_a_tick_and_not_once_a_frame() -> void:
	section("the boxes are rebuilt once a tick, not once a frame")
	var built := _showcase()
	var simulator: BattleSimulator = built["simulator"]
	var view: BattleView = built["view"]
	var level := UnitScale.Level.CENTURY
	var step := UnitScale.size_of(level)
	view.ensure_boxes(level, step)
	equal(view.box_rebuilds, 1, "the first ask built the boxes")
	equal(view.box_count(), simulator.formations.size(),
		"a cohort of twelve men a side is one box a body at this level")
	view.ensure_boxes(level, step)
	view.ensure_boxes(level, step)
	equal(view.box_rebuilds, 1, "and asking again within the tick costs nothing - this is the fix")
	simulator.step(TICK)
	view.ensure_boxes(level, step)
	equal(view.box_rebuilds, 2, "the tick rebuilt them, once")
	var legion := UnitScale.Level.LEGION
	view.ensure_boxes(legion, UnitScale.size_of(legion))
	equal(view.box_rebuilds, 3, "and a camera that changes level rebuilds rather than drawing stale boxes")


func _test_every_living_soldier_stands_inside_his_side_s_boxes() -> void:
	section("every living soldier is inside his side's boxes")
	var built := _showcase()
	var simulator: BattleSimulator = built["simulator"]
	var view: BattleView = built["view"]
	# Small groups on purpose: the boxes are tight, so a man outside one is a real failure rather
	# than a rounding artefact of a legion-sized box.
	var level := UnitScale.Level.CONTUBERNIUM
	var step := UnitScale.size_of(level)
	view.ensure_boxes(level, step)
	# Count the groups holding at least one living man, independently of how the view counts them.
	var expected := 0
	for formation in simulator.formations:
		var seen := {}
		for i in formation.unit_ids.size():
			var member: BattleUnit = simulator.find_unit(formation.unit_ids[i])
			if member == null or not member.is_alive():
				continue
			seen[i / step] = true
		expected += seen.size()
	equal(view.box_count(), expected, "one box per group of living men, over every body")
	var inside := 0
	var outside := 0
	for unit in simulator.units:
		if not unit.is_alive():
			continue
		var found := false
		for rect in view.box_rects():
			if rect.has_point(unit.position):
				found = true
				break
		if found:
			inside += 1
		else:
			outside += 1
	equal(outside, 0, "every living soldier stands inside a box (%d inside, %d outside)" % [inside, outside])


func _test_a_thinned_rank_shows_as_a_smaller_box() -> void:
	section("a thinned rank shows as a smaller box")
	var built := _showcase()
	var simulator: BattleSimulator = built["simulator"]
	var view: BattleView = built["view"]
	var level := UnitScale.Level.CENTURY
	var step := UnitScale.size_of(level)
	view.ensure_boxes(level, step)
	var before := _total_area(view.box_rects())
	# Kill the back half of every player body, the way a fight does.
	for formation in simulator.formations:
		if formation.side != BattleContext.SIDE_PLAYER:
			continue
		var ids := formation.unit_ids
		for i in range(ids.size() / 2, ids.size()):
			var member: BattleUnit = simulator.find_unit(ids[i])
			if member != null:
				member.hp = 0
	simulator.step(TICK)
	view.ensure_boxes(level, step)
	var after := _total_area(view.box_rects())
	check(after < before,
		"the boxes contract as the ranks thin (%.1f to %.1f square units)" % [before, after])


func _total_area(rects: Array[Rect2]) -> float:
	var total := 0.0
	for rect in rects:
		total += rect.size.x * rect.size.y
	return total
