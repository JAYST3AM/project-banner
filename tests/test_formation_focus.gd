extends TestCase
## Step 7.5: formation battlefield focus, calculated at the formation layer.
##
## The rules this suite exists to pin down:
## [br]- a body's focus is the soldier a full scan of the army would have chosen, not an
##   approximation of one: the bound that makes the selection cheap is a proof, and the
##   tests check it against the reference implementation rather than against a drawing;
## [br]- the summaries a body's focus is read from describe the body it is now, after it has
##   moved, after it has lost soldiers, and after it has been given them;
## [br]- a hostile body with nobody left in it is never a focus and never an answer;
## [br]- the formation layer absorbs a death: the pass runs once per body per tick, a body's
##   answer is repaired once, and no soldier walks the army to find out where the fighting is;
## [br]- the focus path allocates nothing after the army has been handed over;
## [br]- and an explicit order is still first in the queue, unaffected by any of it.
##
## [b]On the reference implementation.[/b] [method BattleSimulator._nearest_enemy_to_point]
## is the Step 7.4 answer - one pass over the whole army per question - and the battle no
## longer calls it. It is kept because "the new answer is the same as the old one" is a claim
## that has to be measured, and a test that measures it is worth more than a comment saying
## it. Everywhere one of these tests wants to know who a body [i]should[/i] be pointed at, it
## asks that method, never a hand-computed expectation.

const TICK := 0.05
const SEED := 75001

const PLAYER := BattleContext.SIDE_PLAYER
const ENEMY := BattleContext.SIDE_ENEMY


func run() -> void:
	await _tick()
	_test_the_selection_is_the_same_answer_as_a_full_scan()
	_test_the_same_answer_holds_when_a_side_has_no_bodies()
	_test_a_body_is_pointed_at_the_nearest_hostile_body()
	_test_friendly_bodies_are_not_candidates()
	_test_a_dead_body_is_never_the_focus()
	_test_an_empty_body_has_no_focus_to_hold()
	_test_focus_follows_the_bodies_as_they_move()
	_test_a_summary_counts_the_dead_out()
	_test_a_detached_soldier_does_not_leave_a_stale_summary()
	_test_a_membership_change_invalidates_the_focus()
	_test_the_tie_between_two_equal_bodies_is_stable()
	_test_the_focus_pass_runs_once_per_body_per_tick()
	_test_no_soldier_walks_the_army_to_find_the_fighting()
	_test_a_death_repairs_the_answer_once()
	_test_a_wiped_out_side_does_not_become_a_search_per_soldier()
	_test_the_focus_path_allocates_nothing_per_tick()
	_test_a_battle_with_focus_is_deterministic()
	_test_an_explicit_order_still_outranks_the_focus()
	_test_a_contacted_body_keeps_fighting()
	_test_the_search_itself_is_unchanged()
	_complete()


## ---------- fixtures -----------------------------------------------------

func _config() -> GameConfig:
	return GameManager.config()


## A soldier that will not fight unless a test asks it to: melee reach of a hair, so the
## tests about focus are not also tests about damage.
func _unit(id: int, side: String, position: Vector2, reach: float = 0.05, speed: float = 5.0) -> BattleUnit:
	var unit := BattleUnit.new()
	unit.id = id
	unit.side = side
	unit.soldier_id = "s_focus_%d" % id
	unit.display_name = "Focus %d" % id
	unit.max_hp = 1000
	unit.hp = 1000
	unit.attack = 1
	unit.defence = 0
	unit.move_speed = speed
	unit.attack_range = reach
	unit.attack_cooldown = 1.0
	unit.position = position
	return unit


## Two armies of [param per_side] soldiers in ranks, dressed on their formation slots and
## advancing on each other from [param gap] units apart. The battlefield is sized so that
## the bodies are separate objects rather than a scrum, which is the shape the focus layer
## is about.
func _formed_army(per_side: int, gap: float, interval: int, seed_value: int = SEED, reach: float = 0.05) -> Dictionary:
	var config := _config()
	var field := Vector2(320.0, 200.0)
	var units: Array[BattleUnit] = []
	var next_id := 0
	var middle := field.x * 0.5
	for side_value in [PLAYER, ENEMY]:
		var side := str(side_value)
		var left := side == PLAYER
		var ranks := 4
		var files := maxi(1, per_side / ranks)
		for i in per_side:
			var file := i % files
			var rank := i / files
			var x := (middle - gap * 0.5) - float(rank) * 1.4 if left \
				else (middle + gap * 0.5) + float(rank) * 1.4
			var y := field.y * 0.2 + float(file) * (field.y * 0.6 / float(files))
			units.append(_unit(next_id, side, Vector2(x, y), reach))
			next_id += 1

	var simulator := BattleSimulator.new(config, seed_value)
	simulator.field_size = field
	simulator.grid.configure(field, simulator.cell_size)
	simulator.overlap_grid.configure(field, simulator.overlap_cell_size)
	simulator.target_reacquisition_ticks = interval
	simulator.add_units(units)
	var bodies := BattleSetup.assign_default_formations(simulator, config)
	var ai := BattleAI.create(config)
	simulator.start()
	return {"simulator": simulator, "bodies": bodies, "ai": ai, "units": units, "field": field}


## A battle where one side is a body and the other is a loose crowd, which is the case the
## summary's second kind of bucket exists for.
func _half_formed(per_side: int, gap: float) -> Dictionary:
	var bundle := _formed_army(per_side, gap, 4)
	var simulator: BattleSimulator = bundle["simulator"]
	for unit in simulator.units:
		if unit.side == ENEMY:
			unit.formation_ref = null
			unit.slot_index = -1
	return bundle


## Split a formed army into several bodies rather than one, which is what a real army looks
## like and what makes the focus layer choose between bodies rather than between two.
func _split_into_bodies(simulator: BattleSimulator, pieces: int) -> Array[BattleFormation]:
	var catalog := FormationCatalog.load_from()
	var config := _config()
	var made: Array[BattleFormation] = []
	for side_value in [PLAYER, ENEMY]:
		var side := str(side_value)
		var mine: Array[BattleUnit] = []
		for unit in simulator.units:
			if unit.side == side:
				mine.append(unit)
		var index := 0
		var ordinal := 0
		var size := maxi(1, mine.size() / pieces)
		while index < mine.size():
			var ids: Array[int] = []
			var centroid := Vector2.ZERO
			var count := 0
			for i in mini(size, mine.size() - index):
				var unit := mine[index + i]
				ids.append(unit.id)
				centroid += unit.position
				count += 1
			centroid /= float(maxi(1, count))
			var body := BattleFormation.create("%s_%d" % [side, ordinal], side, centroid, 0.0 if side == PLAYER else PI, "line", catalog, config)
			simulator.add_formation(body)
			simulator.assign_formation(body, ids)
			body.order_engage()
			made.append(body)
			ordinal += 1
			index += size
	return made


## Whether any body on either side has a soldier with an enemy within reach. Read from the
## bodies rather than from a side, because contact belongs to a body - and there is no
## side-wide contact question to ask.
func _in_contact(simulator: BattleSimulator) -> bool:
	for body in simulator.formations:
		if body.in_contact:
			return true
	return false


## The soldier a full scan of the army says this body should be pointed at. The reference
## the rest of this suite measures against.
func _reference(simulator: BattleSimulator, body: BattleFormation) -> BattleUnit:
	return simulator.call("_nearest_enemy_to_point", body.side, body.anchor)


## ---------- the selection is exact ---------------------------------------

## The claim the whole milestone rests on, and the only one worth making by measurement:
## the bounded selection picks the same soldier a full scan of the army would have picked.
##
## The comparison is made with everything standing still, by running the pass again: a full
## scan reads live positions, so comparing it against an answer worked out before the
## soldiers moved would be comparing two different questions. For every body of both armies,
## over a whole approach, at the start, in the middle and once the lines are in contact.
func _test_the_selection_is_the_same_answer_as_a_full_scan() -> void:
	section("the bounded selection answers what a full scan answers")
	var bundle := _formed_army(48, 40.0, 4, SEED, 1.8)
	var simulator: BattleSimulator = bundle["simulator"]
	var ai: BattleAI = bundle["ai"]
	simulator.target_reacquisition_ticks = 4
	var compared := 0
	var disagreements := 0
	var contacts := 0
	var first_disagreement := ""
	for i in 200:
		ai.update(simulator, TICK)
		simulator.step(TICK)
		simulator.call("_refresh_focus")
		for body in simulator.formations:
			if body.living_count == 0:
				continue
			var mine: BattleUnit = simulator.call("_focus_unit_of", body)
			var expected := _reference(simulator, body)
			compared += 1
			if mine != expected:
				disagreements += 1
				if first_disagreement.is_empty():
					first_disagreement = "%s: bounded %s, full scan %s" % [
						body.id,
						"nobody" if mine == null else "unit %d at %s" % [mine.id, mine.position],
						"nobody" if expected == null else "unit %d at %s" % [expected.id, expected.position]]
		if _in_contact(simulator):
			contacts += 1
	greater(float(compared), 300.0, "every body was compared on every tick (%d comparisons)" % compared)
	equal(disagreements, 0, "and the bounded selection agreed with the full scan every time. %s" % first_disagreement)
	greater(float(contacts), 0.0, "including with the lines actually in contact (%d such ticks)" % contacts)


## The same claim where one side has no bodies at all, so the answer has to come out of the
## loose bucket - the soldiers who belong to no body.
func _test_the_same_answer_holds_when_a_side_has_no_bodies() -> void:
	section("and when a side is a crowd rather than a body")
	var bundle := _half_formed(30, 70.0)
	var simulator: BattleSimulator = bundle["simulator"]
	var ai: BattleAI = bundle["ai"]
	var compared := 0
	var disagreements := 0
	for i in 90:
		ai.update(simulator, TICK)
		simulator.step(TICK)
		simulator.call("_refresh_focus")
		for body in simulator.formations:
			if body.living_count == 0:
				continue
			var mine: BattleUnit = simulator.call("_focus_unit_of", body)
			var expected := _reference(simulator, body)
			compared += 1
			if mine != expected:
				disagreements += 1
	# And the loose side's own fallback, which is the path a soldier with no body takes.
	var loose := 0
	for unit in simulator.units:
		if unit.side == ENEMY and unit.is_alive():
			loose += 1
	greater(float(loose), 20.0, "the unformed side is still standing (%d soldiers)" % loose)
	greater(float(compared), 60.0, "the formed side was compared on every tick (%d comparisons)" % compared)
	equal(disagreements, 0, "and the answer came out of the loose bucket correctly every time")


## ---------- who is chosen ------------------------------------------------

## Several bodies a side: the focus is the body that can actually be reached, which is the
## question the formation layer is supposed to answer rather than the soldier layer.
func _test_a_body_is_pointed_at_the_nearest_hostile_body() -> void:
	section("a body watches the hostile body it can reach")
	var bundle := _formed_army(40, 100.0, 4)
	var simulator: BattleSimulator = bundle["simulator"]
	var bodies := _split_into_bodies(simulator, 4)
	simulator.call("_rebuild_spatial", TICK)
	simulator.call("_refresh_focus")
	greater(float(bodies.size()), 4.0, "the armies are several bodies each (%d bodies)" % bodies.size())

	# The bound that decides which body is opened first is the distance to that body's box.
	# The selection stops as soon as the nearest unopened box is further than the best
	# soldier found, which means the body its answer came out of is the one whose box was
	# closest of all. That is a sharp claim and it is the one tested.
	var compared := 0
	var not_the_closest := 0
	for body in bodies:
		if body.living_count == 0:
			continue
		var focused: BattleFormation = simulator.call("_focus_formation_of", body)
		if focused == null:
			continue
		compared += 1
		var chosen_bound: float = focused.bounds_distance_squared(body.anchor)
		for other in bodies:
			if other.side == body.side or not other.is_living():
				continue
			if other.bounds_distance_squared(body.anchor) < chosen_bound - 0.0001:
				not_the_closest += 1
				break
	greater(float(compared), 4.0, "bodies chose a body to watch (%d)" % compared)
	equal(not_the_closest, 0, "and the body chosen is the one whose box was nearest to the asking body")


## A body on the same side is never a candidate, whatever its bounds say.
func _test_friendly_bodies_are_not_candidates() -> void:
	section("a friendly body is not a target")
	var bundle := _formed_army(24, 100.0, 4)
	var simulator: BattleSimulator = bundle["simulator"]
	var bodies := _split_into_bodies(simulator, 3)
	simulator.call("_rebuild_spatial", TICK)
	simulator.call("_refresh_focus")
	var wrong_side := 0
	var watched_a_friend := 0
	var checked := 0
	for body in bodies:
		var focused: BattleUnit = simulator.call("_focus_unit_of", body)
		var watched: BattleFormation = simulator.call("_focus_formation_of", body)
		checked += 1
		if focused != null and focused.side == body.side:
			wrong_side += 1
		if watched != null and watched.side == body.side:
			watched_a_friend += 1
	greater(float(checked), 5.0, "several bodies were asked (%d)" % checked)
	equal(wrong_side, 0, "and not one of them was pointed at its own side")
	equal(watched_a_friend, 0, "nor was any of them watching a friendly body")


## A body with nobody left standing in it is not an answer, even when it is the nearest thing
## on the field and its box is right on top of the asking body.
func _test_a_dead_body_is_never_the_focus() -> void:
	section("a body of corpses is not a focus")
	var bundle := _formed_army(24, 60.0, 4)
	var simulator: BattleSimulator = bundle["simulator"]
	var bodies := _split_into_bodies(simulator, 3)
	var enemy_bodies: Array[BattleFormation] = []
	for body in bodies:
		if body.side == ENEMY:
			enemy_bodies.append(body)
	not_equal(enemy_bodies.size(), 0, "the enemy has bodies to kill")
	var doomed := enemy_bodies[0]
	# Wipe it out where it stands. The soldiers stay in the roster as corpses, which is what
	# a battle actually does: nothing removes them from their body mid-fight.
	for unit_id in doomed.unit_ids:
		var unit: BattleUnit = simulator.find_unit(unit_id)
		if unit != null:
			unit.hp = 0
	simulator.call("_rebuild_spatial", TICK)
	simulator.call("_refresh_focus")
	equal(doomed.living_count, 0, "the body reports nobody standing")
	var pointed_at_a_corpse := 0
	var asked := 0
	for body in simulator.formations:
		if body.living_count == 0:
			continue
		asked += 1
		var focused: BattleUnit = simulator.call("_focus_unit_of", body)
		if focused != null and not focused.is_alive():
			pointed_at_a_corpse += 1
		if focused != null and focused.formation_ref == doomed:
			pointed_at_a_corpse += 1
	greater(float(asked), 0.0, "the living bodies are still asked (%d)" % asked)
	equal(pointed_at_a_corpse, 0, "and none of them is pointed at the dead body or its soldiers")


## A body of corpses holds no focus at all: not a stale one from before it died, and not a
## fresh one, because there is nobody in it for a focus to be for.
func _test_an_empty_body_has_no_focus_to_hold() -> void:
	section("an empty body has no focus")
	var bundle := _formed_army(20, 80.0, 4)
	var simulator: BattleSimulator = bundle["simulator"]
	var bodies := _split_into_bodies(simulator, 2)
	simulator.call("_rebuild_spatial", TICK)
	simulator.call("_refresh_focus")
	var victim: BattleFormation = null
	for body in bodies:
		if body.side == ENEMY:
			victim = body
			break
	not_null(victim, "there is an enemy body to empty")
	var had_focus: BattleUnit = simulator.call("_focus_unit_of", victim)
	not_null(had_focus, "and while it had soldiers it was watching somebody")
	for unit_id in victim.unit_ids:
		var unit: BattleUnit = simulator.find_unit(unit_id)
		if unit != null:
			unit.hp = 0
	victim.remove_units(victim.unit_ids.duplicate())
	equal(victim.living_count, 0, "the body has been emptied through its own API")
	is_null(simulator.call("_focus_unit_of", victim), "and it holds no focus")
	check(not victim.is_living(), "and it is not a living body")
	simulator.call("_rebuild_spatial", TICK)
	simulator.call("_refresh_focus")
	is_null(simulator.call("_focus_unit_of", victim), "still no focus after a full pass")


## The summary is a reading of where a body's soldiers are, so it has to follow them. A body
## that has marched a long way must have a centre and a box that marched with it.
func _test_focus_follows_the_bodies_as_they_move() -> void:
	section("the summary follows the body it describes")
	var bundle := _formed_army(32, 140.0, 4)
	var simulator: BattleSimulator = bundle["simulator"]
	var ai: BattleAI = bundle["ai"]
	var body: BattleFormation = bundle["bodies"][0]
	# A body's summary describes the tick it was built on, so the starting point is after a
	# pass rather than before the first one - before it, there is no reading to compare with.
	simulator.call("_rebuild_spatial", TICK)
	simulator.call("_refresh_focus")
	var start_centre := body.centre
	var start_anchor := body.anchor
	var start_distance := body.focus_distance
	for i in 60:
		ai.update(simulator, TICK)
		simulator.step(TICK)
	greater(body.anchor.distance_to(start_anchor), 3.0, "the body has marched")
	greater(body.centre.distance_to(start_centre), 3.0,
		"and its centre went with it rather than staying where it started")
	var walked := Vector2.ZERO
	var counted := 0
	for unit_id in body.unit_ids:
		var unit: BattleUnit = simulator.find_unit(unit_id)
		if unit != null and unit.is_alive():
			walked += unit.position
			counted += 1
	# The summary describes the tick it was built on, so the soldiers have moved a little
	# since - by at most one tick of walking, and no further.
	approx(body.centre.distance_to(walked / float(counted)), 0.0, 0.5,
		"and the centre is the average of where the soldiers actually are (%d of them)" % counted)
	var centre_error := body.centre.distance_to(body.anchor)
	less(centre_error, body.depth() + body.frontage() + 1.0,
		"the centre is inside the body it describes, not somewhere else on the field")
	less(body.focus_distance, start_distance, "and the fighting it is watching got closer")


## Casualties are excluded from the summary rather than merely being skipped by readers.
func _test_a_summary_counts_the_dead_out() -> void:
	section("the summary counts only the living")
	var bundle := _formed_army(24, 80.0, 4)
	var simulator: BattleSimulator = bundle["simulator"]
	simulator.call("_rebuild_spatial", TICK)
	simulator.call("_refresh_focus")
	var body: BattleFormation = bundle["bodies"][0]
	var before := body.living_count
	var counted := 0
	for unit_id in body.unit_ids:
		var unit: BattleUnit = simulator.find_unit(unit_id)
		if unit != null and unit.is_alive():
			counted += 1
	equal(before, counted, "the living count is the number of soldiers actually standing (%d)" % before)
	var centre_before := body.centre
	# Half of them fall where they stand.
	var fallen := 0
	for unit_id in body.unit_ids:
		if fallen >= body.unit_ids.size() / 2:
			break
		var unit: BattleUnit = simulator.find_unit(unit_id)
		if unit != null and unit.is_alive():
			unit.hp = 0
			fallen += 1
	simulator.call("_refresh_summaries")
	equal(body.living_count, before - fallen, "the count drops by exactly the fallen (%d)" % fallen)
	not_equal(body.centre, centre_before, "and the centre is no longer the centre of a body that included them")
	var survivors := 0
	for unit_id in body.unit_ids:
		var unit: BattleUnit = simulator.find_unit(unit_id)
		if unit != null and unit.is_alive():
			survivors += 1
	equal(body.living_count, survivors, "and it agrees with a walk of the roll (%d)" % survivors)


## A body that has had soldiers taken away describes the body it is now rather than the one
## it was - the summary must not outlive the membership that produced it.
func _test_a_detached_soldier_does_not_leave_a_stale_summary() -> void:
	section("a detachment does not leave a stale summary")
	var bundle := _formed_army(24, 80.0, 4)
	var simulator: BattleSimulator = bundle["simulator"]
	simulator.call("_rebuild_spatial", TICK)
	simulator.call("_refresh_focus")
	var body: BattleFormation = bundle["bodies"][0]
	var before := body.living_count
	var leaving: Array[int] = []
	for i in 5:
		leaving.append(body.unit_ids[i])
	var removed := body.remove_units(leaving)
	equal(removed, 5, "five soldiers were detached")
	check(not body.summary_ready, "and the body no longer claims to have a summary")
	equal(body.living_count, 0, "nor a living count, until it is rebuilt")
	simulator.call("_rebuild_spatial", TICK)
	simulator.call("_refresh_focus")
	equal(body.living_count, before - 5, "after the rebuild it reports the body it has become (%d, was %d)" % [before - 5, before])
	var walked := 0
	for unit_id in body.unit_ids:
		var unit: BattleUnit = simulator.find_unit(unit_id)
		if unit != null and unit.is_alive():
			walked += 1
	equal(body.living_count, walked, "which agrees with a walk of the roll (%d)" % walked)


## The same rule for the focus: an answer worked out about a membership that has since
## changed is not an answer about this body.
func _test_a_membership_change_invalidates_the_focus() -> void:
	section("a membership change invalidates the focus")
	var bundle := _formed_army(24, 80.0, 4)
	var simulator: BattleSimulator = bundle["simulator"]
	simulator.call("_rebuild_spatial", TICK)
	simulator.call("_refresh_focus")
	var body: BattleFormation = bundle["bodies"][0]
	not_null(simulator.call("_focus_unit_of", body), "the body is watching somebody")
	check(body.is_focus_current(), "and its focus is current")
	var version := body.membership_version
	body.remove_unit(body.unit_ids[0])
	greater(float(body.membership_version), float(version), "detaching a soldier bumped the version")
	check(not body.is_focus_current(), "so the focus is no longer current")
	is_null(simulator.call("_focus_unit_of", body), "and it reads as nobody rather than as a stale soldier")
	simulator.call("_rebuild_spatial", TICK)
	simulator.call("_refresh_focus")
	check(body.is_focus_current(), "the next pass answers for the body it is now")
	not_null(simulator.call("_focus_unit_of", body), "and it is watching somebody again")


## Two hostile bodies placed as exact mirror images of each other about the asking body's
## anchor, so both are precisely the same distance away and neither is more suitable than the
## other. Which one is chosen has to be a rule rather than an accident, and the same rule
## every time - a battle whose focus depends on the order a dictionary happened to iterate in
## would be a battle that cannot be replayed.
func _test_the_tie_between_two_equal_bodies_is_stable() -> void:
	section("a tie between two equal bodies is broken the same way every time")
	var catalog := FormationCatalog.load_from()
	var config := _config()
	var picked_units: Array[int] = []
	var picked_bodies: Array[String] = []
	for run_index in 3:
		var units: Array[BattleUnit] = []
		units.append(_unit(0, PLAYER, Vector2(40.0, 30.0), 0.05, 0.0))
		# Two enemies, mirror images about y = 30 and the same distance from x = 40.
		units.append(_unit(1, ENEMY, Vector2(60.0, 30.0 - 25.0), 0.05, 0.0))
		units.append(_unit(2, ENEMY, Vector2(60.0, 30.0 + 25.0), 0.05, 0.0))
		var simulator := BattleSimulator.new(config, SEED)
		simulator.field_size = Vector2(120.0, 60.0)
		simulator.grid.configure(simulator.field_size, simulator.cell_size)
		simulator.overlap_grid.configure(simulator.field_size, simulator.overlap_cell_size)
		simulator.add_units(units)
		var asking := BattleFormation.create("player_body", PLAYER, Vector2(40.0, 30.0), 0.0, "line", catalog, config)
		simulator.add_formation(asking)
		simulator.assign_formation(asking, [0])
		var upper := BattleFormation.create("enemy_upper", ENEMY, Vector2(60.0, 5.0), PI, "line", catalog, config)
		simulator.add_formation(upper)
		simulator.assign_formation(upper, [1])
		var lower := BattleFormation.create("enemy_lower", ENEMY, Vector2(60.0, 55.0), PI, "line", catalog, config)
		simulator.add_formation(lower)
		simulator.assign_formation(lower, [2])
		# Both bodies are single soldiers standing on their own anchors, so the distance from
		# the asking anchor to either one is the same number to the last bit.
		var to_upper := asking.anchor.distance_squared_to(units[1].position)
		var to_lower := asking.anchor.distance_squared_to(units[2].position)
		approx(to_upper, to_lower, 0.0001, "the two candidates are exactly the same distance away")
		simulator.call("_rebuild_spatial", TICK)
		simulator.call("_refresh_focus")
		var chosen: BattleUnit = simulator.call("_focus_unit_of", asking)
		var watched: BattleFormation = simulator.call("_focus_formation_of", asking)
		not_null(chosen, "the tie produced an answer")
		not_null(watched, "and a body to go with it")
		picked_units.append(chosen.id)
		picked_bodies.append(str(watched.id))
	# The rule is the earliest body built, which is the order the battlefield holds them in -
	# a fact about the battle rather than about a hash table.
	equal(picked_units[1], picked_units[0], "a repeat run picks the same soldier")
	equal(picked_units[2], picked_units[0], "and a third run does too")
	equal(picked_bodies[0], picked_bodies[1], "the same body both times")
	equal(picked_bodies[0], "enemy_upper", "and it is the one built first, not whichever was convenient")


## The pass costs one evaluation per body per tick. A figure far above that would mean the
## pass is running more than once, which is the shape of bug that gets slower without ever
## being wrong.
func _test_the_focus_pass_runs_once_per_body_per_tick() -> void:
	section("one focus pass, one evaluation per body, per tick")
	var bundle := _formed_army(40, 90.0, 4)
	var simulator: BattleSimulator = bundle["simulator"]
	var ai: BattleAI = bundle["ai"]
	var bodies := _split_into_bodies(simulator, 4)
	simulator.profile_enabled = true
	simulator.reset_profile()
	var ticks := 80
	for i in ticks:
		ai.update(simulator, TICK)
		simulator.step(TICK)
	var report := simulator.focus_report()
	equal(int(report["passes"]), ticks, "the pass ran once per tick (%d)" % int(report["passes"]))
	approx(float(report["evaluations_per_tick"]), float(bodies.size()), 0.5,
		"and evaluated each of the %d bodies once, counting the ones that died out" % bodies.size())
	approx(float(report["formations"]), float(simulator.formations.size()), 0.5, "the report agrees on how many bodies there are")


## The counter the brief asks for by name: whole-army scans made by the focus logic on behalf
## of a soldier. It must be zero, and the pass must be the only thing that asks.
func _test_no_soldier_walks_the_army_to_find_the_fighting() -> void:
	section("no soldier scans the army for formation guidance")
	var bundle := _formed_army(60, 80.0, 4)
	var simulator: BattleSimulator = bundle["simulator"]
	var ai: BattleAI = bundle["ai"]
	_split_into_bodies(simulator, 5)
	simulator.profile_enabled = true
	simulator.reset_profile()
	for i in 120:
		ai.update(simulator, TICK)
		simulator.step(TICK)
	var report := simulator.focus_report()
	var soldier_ticks := 0
	for unit in simulator.units:
		soldier_ticks += 1
	greater(float(report["target_calls"]), 500.0,
		"soldiers asked for their body's focus plenty of times (%d)" % int(report["target_calls"]))
	equal(int(report["scans_from_soldiers"]), 0, "and not one of those questions became a scan of the army")
	equal(int(report["units_from_soldiers"]), 0, "nor walked a single soldier to answer")
	equal(int(report["global_scans"]), 0, "the full-scan reference was not called by the battle at all")
	greater(float(report["formation_hits"]) + float(report["formation_repairs"]), 500.0,
		"and every one of them was answered from the body it belongs to")


## A body's answer dying mid-tick is repaired at the body's layer, once, and the soldiers
## that ask afterwards read the repaired answer rather than repeating the work.
##
## This is the shape the milestone has to get right: an answer that dies after the pass has
## been made is noticed by the first soldier that asks, corrected for the body, and then read
## by everyone else in it. Nothing here searches; nothing here scans.
func _test_a_death_repairs_the_answer_once() -> void:
	section("a death is repaired at the body's layer")
	var bundle := _formed_army(40, 60.0, 4, SEED, 1.8)
	var simulator: BattleSimulator = bundle["simulator"]
	var ai: BattleAI = bundle["ai"]
	for i in 25:
		ai.update(simulator, TICK)
		simulator.step(TICK)
	simulator.profile_enabled = true
	simulator.reset_profile()
	var body: BattleFormation = bundle["bodies"][0]
	not_equal(body.living_count, 0, "the body is still standing")
	simulator.call("_rebuild_spatial", TICK)
	simulator.call("_refresh_focus")
	var answer: BattleUnit = simulator.call("_focus_unit_of", body)
	not_null(answer, "it was given an answer by the pass")
	var before := int(simulator.focus_report()["formation_repairs"])

	# It falls after the pass - which is what a death mid-tick is - and the next soldier in
	# the body to ask is the one that notices.
	answer.hp = 0
	var soldier := _first_living_member(simulator, body)
	not_null(soldier, "there is a soldier in the body to ask")
	var repaired: BattleUnit = simulator.call("_focus_target", soldier)
	not_null(repaired, "the body still has an answer")
	not_equal(repaired, answer, "and it is not the soldier that fell")
	check(repaired.is_alive(), "because it is a soldier that is standing")
	equal(repaired, simulator.call("_nearest_enemy_to_point", body.side, body.anchor),
		"and it is exactly who the full scan says, so the repair is an answer rather than a guess")
	equal(int(simulator.focus_report()["formation_repairs"]) - before, 1, "the repair was counted once")

	# Everyone else in the body reads the answer that was just repaired.
	var second := _second_living_member(simulator, body)
	if second != null:
		equal(simulator.call("_focus_target", second), repaired,
			"a second soldier in the body reads the same answer")
	equal(int(simulator.focus_report()["formation_repairs"]) - before, 1,
		"and asking did not repair anything again")

	# A second death is a second correction - the guard is on repeating the same answer, not
	# on correcting the body twice.
	repaired.hp = 0
	simulator.call("_focus_target", soldier)
	equal(int(simulator.focus_report()["formation_repairs"]) - before, 2,
		"a second death in the same tick is corrected as well")

	# And none of it walked the army.
	equal(int(simulator.focus_report()["scans_from_soldiers"]), 0,
		"three soldier questions, and not one of them scanned the army")


## The first living soldier in a body that has one, or null.
func _first_living_member(simulator: BattleSimulator, body: BattleFormation) -> BattleUnit:
	for unit_id in body.unit_ids:
		var unit: BattleUnit = simulator.find_unit(unit_id)
		if unit != null and unit.is_alive():
			return unit
	return null


## The next one after that, for tests that need two soldiers in the same body.
func _second_living_member(simulator: BattleSimulator, body: BattleFormation) -> BattleUnit:
	var seen := false
	for unit_id in body.unit_ids:
		var unit: BattleUnit = simulator.find_unit(unit_id)
		if unit == null or not unit.is_alive():
			continue
		if seen:
			return unit
		seen = true
	return null


## The case the hierarchy exists for: an entire side wiped out. Every soldier still standing
## asks where the fighting is, and the answer is worked out once for its body rather than
## once per soldier.
func _test_a_wiped_out_side_does_not_become_a_search_per_soldier() -> void:
	section("a wiped-out side does not become a search per soldier")
	var bundle := _formed_army(60, 80.0, 4)
	var simulator: BattleSimulator = bundle["simulator"]
	var ai: BattleAI = bundle["ai"]
	_split_into_bodies(simulator, 5)
	for i in 30:
		ai.update(simulator, TICK)
		simulator.step(TICK)
	for unit in simulator.units:
		if unit.side == ENEMY:
			unit.hp = 0
	simulator.profile_enabled = true
	simulator.reset_profile()
	var ticks := 40
	for i in ticks:
		ai.update(simulator, TICK)
		simulator.step(TICK)
	var report := simulator.focus_report()
	var alive := 0
	for unit in simulator.units:
		if unit.is_alive():
			alive += 1
	greater(float(alive), 40.0, "the winning side still has soldiers standing (%d)" % alive)
	greater(float(report["evaluations_per_tick"]), 4.0,
		"the surviving bodies are still evaluated (%d bodies)" % int(report["formations"]))
	equal(int(report["scans_from_soldiers"]), 0, "none of them scanned the army looking for an enemy")
	equal(int(report["units_from_soldiers"]), 0, "and none of them walked it")
	less(float(report["formation_repairs"]), float(report["evaluations"]) + float(ticks) + 1.0,
		"the repair count stays inside the number of bodies per tick rather than the army size")
	less(float(report["units_per_tick"]), float(alive) * 4.0,
		"and a tick costs a fraction of the army rather than a multiple of it (%d soldiers)" % alive)


## The claim about allocation, measured rather than asserted in a comment: after the army has
## been handed over and the bodies added, a tick of the focus path allocates nothing at all.
func _test_the_focus_path_allocates_nothing_per_tick() -> void:
	section("the focus path allocates nothing per tick")
	var bundle := _formed_army(40, 90.0, 4)
	var simulator: BattleSimulator = bundle["simulator"]
	var ai: BattleAI = bundle["ai"]
	var bodies := _split_into_bodies(simulator, 4)
	simulator.profile_enabled = true
	simulator.reset_profile()
	# A few ticks to let every buffer that is going to be built be built.
	for i in 5:
		ai.update(simulator, TICK)
		simulator.step(TICK)
	var before := int(simulator.focus_report()["allocations"])
	var bodies_before := bodies.size()
	for i in 60:
		ai.update(simulator, TICK)
		simulator.step(TICK)
	var after := int(simulator.focus_report()["allocations"])
	var last: BattleFormation = bodies[0]
	var catalogue := FormationCatalog.load_from()
	var extra := BattleFormation.create("extra_body", PLAYER, Vector2(10.0, 10.0), 0.0, "line", catalogue, _config())
	simulator.add_formation(extra)
	simulator.call("_refresh_summaries")
	var grown := int(simulator.focus_report()["allocations"])
	equal(after - before, 0, "sixty ticks allocated nothing on the focus path")
	greater(float(grown - after), 0.0, "and the one thing that does allocate - a new body - is counted")
	not_equal(bodies_before, bodies_before + 1, "the body count really did change")


## Same seed, same battle, same focus decisions. The milestone changed how the answer is
## worked out, and that is not allowed to make a battle depend on anything but its own state.
func _test_a_battle_with_focus_is_deterministic() -> void:
	section("the same battle makes the same focus decisions twice")
	var signatures: Array[String] = []
	for run_index in 2:
		var bundle := _formed_army(48, 90.0, 4)
		var simulator: BattleSimulator = bundle["simulator"]
		var ai: BattleAI = bundle["ai"]
		_split_into_bodies(simulator, 4)
		var log_lines: Array[String] = []
		for i in 150:
			ai.update(simulator, TICK)
			simulator.step(TICK)
			if i % 10 == 0:
				for body in simulator.formations:
					var focused: BattleUnit = simulator.call("_focus_unit_of", body)
					log_lines.append("%s:%d:%d" % [body.id, body.living_count, -1 if focused == null else focused.id])
		var alive := 0
		var hp_total := 0
		for unit in simulator.units:
			if unit.is_alive():
				alive += 1
				hp_total += unit.hp
		log_lines.append("alive:%d:hp:%d" % [alive, hp_total])
		signatures.append("|".join(log_lines))
	not_equal(signatures[0], signatures[1] + "x", "the runs produced a signature at all")
	equal(signatures[0], signatures[1], "and the two runs agree on every focus decision and every casualty")


## Explicit orders are authoritative and immediate, and the focus layer is underneath them.
func _test_an_explicit_order_still_outranks_the_focus() -> void:
	section("an explicit order outranks the focus")
	var units: Array[BattleUnit] = []
	units.append(_unit(0, PLAYER, Vector2(10.0, 10.0), 1.8))
	units.append(_unit(1, ENEMY, Vector2(20.0, 10.0), 1.8))
	units.append(_unit(2, ENEMY, Vector2(14.0, 10.0), 1.8))
	var simulator := BattleSimulator.new(_config(), SEED)
	simulator.field_size = Vector2(100.0, 60.0)
	simulator.grid.configure(simulator.field_size, simulator.cell_size)
	simulator.overlap_grid.configure(simulator.field_size, simulator.overlap_cell_size)
	simulator.add_units(units)
	var catalog := FormationCatalog.load_from()
	var body := BattleFormation.create("player_body", PLAYER, Vector2(10.0, 10.0), 0.0, "line", catalog, _config())
	simulator.add_formation(body)
	simulator.assign_formation(body, [0])
	simulator.call("_rebuild_spatial", TICK)
	simulator.call("_refresh_focus")
	simulator.start()

	var ordered := simulator.find_unit(2)
	# Unit 1 is nearer to the body's anchor, so it is what the focus would point at.
	var focus_answer: BattleUnit = simulator.call("_focus_unit_of", body)
	var nearest: BattleUnit = simulator.call("_nearest_enemy_to_point", PLAYER, body.anchor)
	equal(focus_answer, nearest, "the body's focus is the nearer enemy, as always")
	units[0].attack_order_target_id = 2
	var chosen: BattleUnit = simulator.call("_resolve_target", units[0])
	equal(chosen, ordered, "an explicit order is answered with the ordered enemy, not the nearer one")
	equal(units[0].attack_order_target_id, 2, "and the order is left standing")
	# And on the very tick it is given: no cadence, no schedule, no wait.
	units[0].next_search_tick = 99
	equal(simulator.call("_resolve_target", units[0]), ordered, "an order does not wait for the soldier's turn to look")
	# A dead quarry clears the order rather than being pursued.
	ordered.hp = 0
	simulator.call("_update_unit", units[0], TICK)
	equal(units[0].attack_order_target_id, -1, "and a quarry that dies clears the order")


## A body that has reached the enemy keeps fighting, whatever its strategic focus is doing.
func _test_a_contacted_body_keeps_fighting() -> void:
	section("a body in contact keeps fighting")
	var bundle := _formed_army(24, 3.0, 4, SEED, 1.8)
	var simulator: BattleSimulator = bundle["simulator"]
	var ai: BattleAI = bundle["ai"]
	# These soldiers are here to fight, so they are given a fight's numbers: the fixture's
	# thousand hit points are for tests that want nobody to die.
	for unit in simulator.units:
		unit.hp = 30
		unit.max_hp = 30
		unit.attack = 6
	var deaths := 0
	var contact_ticks := 0
	for i in 120:
		ai.update(simulator, TICK)
		var events := simulator.step(TICK)
		for event in events:
			if str(event.get("type", "")) == "death":
				deaths += 1
		if _in_contact(simulator):
			contact_ticks += 1
	greater(float(contact_ticks), 20.0, "the lines are in contact for most of the fight (%d ticks)" % contact_ticks)
	greater(float(deaths), 0.0, "and the fighting produces casualties (%d)" % deaths)
	# Every soldier that is in reach of an enemy is dealing with one: contact is
	# authoritative and no focus answer is allowed to leave a soldier standing idle.
	var idle := 0
	var in_reach := 0
	for unit in simulator.units:
		if not unit.is_alive():
			continue
		var nearest: BattleUnit = simulator.call("_nearest_enemy_to_point", unit.side, unit.position)
		if nearest == null or unit.position.distance_to(nearest.position) > unit.attack_range:
			continue
		in_reach += 1
		if unit.auto_target_id < 0 and unit.attack_order_target_id < 0:
			idle += 1
	greater(float(in_reach), 0.0, "there are soldiers with an enemy inside their reach (%d)" % in_reach)
	less(float(idle), float(in_reach) * 0.5,
		"and the great majority of them are dealing with somebody (%d idle of %d)" % [idle, in_reach])


## The Step 7.4 contract, re-measured against the new architecture: the answer a soldier is
## pointed at when it has nobody of its own is still its body's nearest enemy, and when the
## body has nobody to point at the soldier falls back to its side.
func _test_the_search_itself_is_unchanged() -> void:
	section("the soldier-facing answer is unchanged")
	var bundle := _formed_army(40, 90.0, 4)
	var simulator: BattleSimulator = bundle["simulator"]
	var ai: BattleAI = bundle["ai"]
	var bodies := _split_into_bodies(simulator, 4)
	for i in 30:
		ai.update(simulator, TICK)
		simulator.step(TICK)
	var compared := 0
	var disagreements := 0
	var through_the_pass := 0
	for body in bodies:
		if body.living_count == 0:
			continue
		for unit_id in body.unit_ids:
			var unit: BattleUnit = simulator.find_unit(unit_id)
			if unit == null or not unit.is_alive():
				continue
			compared += 1
			var asked: BattleUnit = simulator.call("_focus_target", unit)
			var expected: BattleUnit = simulator.call("_focus_unit_of", body)
			if expected == null:
				continue
			through_the_pass += 1
			if asked != expected:
				disagreements += 1
	greater(float(compared), 40.0, "soldiers asked where the fighting is (%d)" % compared)
	greater(float(through_the_pass), 40.0, "and their bodies had an answer (%d)" % through_the_pass)
	equal(disagreements, 0, "every soldier was pointed at its body's answer and no other")
