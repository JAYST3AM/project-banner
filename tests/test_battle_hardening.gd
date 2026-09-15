extends TestCase
## Step 7.8B - large-battle stalemate hardening.
##
## The 300 v 300 showcase froze at half casualties: 302 dead, 298 standing, nobody within
## reach of anybody, and no further casualties for thousands of ticks while both armies
## lived. This suite is the evidence that it cannot happen again, expressed as the smallest
## cases that reproduce the mechanism rather than as one long battle:
##
## [br]- a line whose front rank has been killed still has a front, and its station moves
##   forward by the rank it lost ([method _test_the_station_follows_the_surviving_front]);
## [br]- contact is re-established after those casualties and the fighting continues
##   ([method _test_a_thinned_line_keeps_fighting]);
## [br]- two engaging bodies never drive their centres into each other, which is the state
##   the frozen battle ended in ([method _test_centres_never_converge]);
## [br]- a body whose soldiers may press forward is the body whose line has stopped fighting,
##   and pressing stops again the moment contact returns
##   ([method _test_pressing_follows_contact]);
## [br]- a body that cannot express the last step onto its station has [i]arrived[/i] rather
##   than reporting itself moving forever ([method _test_an_unexpressible_step_is_an_arrival]);
## [br]- HOLD still holds, a wiped body is not chased, and contact stays formation-local;
## [br]- the same seed fights the same battle, including under different frame pacing
##   ([method _test_same_seed_same_battle], [method _test_frame_pacing_does_not_change_a_battle]);
## [br]- and three hundred a side reaches a result ([method _test_three_hundred_a_side_resolves]).
##
## See D-100 for the recorded failure and D-101..D-103 for what was done about it.

const SIDE_PLAYER := BattleContext.SIDE_PLAYER
const SIDE_ENEMY := BattleContext.SIDE_ENEMY
## The step every other battle in this repository is driven at: 1 / battle.tick_rate.
const STEP := 0.05
## The showcase's own seed, so the headline case is the battle the bug was found in.
const SHOWCASE_SEED := 780780


func run() -> void:
	await _tick()
	_test_an_intact_line_stops_where_it_always_did()
	_test_the_station_follows_the_surviving_front()
	_test_centres_never_converge()
	_test_a_thinned_line_keeps_fighting()
	_test_pressing_follows_contact()
	_test_an_unexpressible_step_is_an_arrival()
	_test_hold_still_holds()
	_test_an_engaged_body_closes_and_reconnects()
	_test_a_wiped_body_is_not_pursued_for_ever()
	_test_contact_stays_formation_local()
	_test_same_seed_same_battle()
	_test_frame_pacing_does_not_change_a_battle()
	_test_three_hundred_a_side_resolves()
	_test_the_production_clock_ends_a_live_fight()
	_test_the_battle_journal_writes_the_transitions()
	GameManager.end_campaign()
	_complete()


## ---------- fixtures -----------------------------------------------------
##
## Formations built here stand on the real field with the real separation pass and the real
## damage rules; the soldiers are probes because these tests are about geometry and orders
## rather than about a campaign. The spearman's own numbers are used for reach and pace, so
## "within reach" means the same thing here as in a real fight.

func _config() -> GameConfig:
	return GameManager.config()


func _contact_gap() -> float:
	return _config().get_float("formation.enemy_contact_gap", 1.5)


func _spacing() -> float:
	return _config().get_float("formation.base_spacing", 2.6)


func _probe_unit(id: int, side: String, position: Vector2, speed: float) -> BattleUnit:
	var unit := BattleUnit.new()
	unit.id = id
	unit.side = side
	unit.soldier_id = "s_hard_%d" % id
	unit.display_name = "Probe %d" % id
	unit.max_hp = 42
	unit.hp = 42
	unit.attack = 7
	unit.defence = 4
	unit.move_speed = speed
	unit.attack_range = 2.4
	unit.attack_cooldown = 1.5
	unit.position = position
	return unit


## A body of [param count] soldiers, dressed on the places it was given.
func _add_body(
	simulator: BattleSimulator,
	id: String,
	side: String,
	anchor: Vector2,
	facing: float,
	count: int,
	first_unit_id: int,
	speed: float = 5.0
) -> BattleFormation:
	var units: Array[BattleUnit] = []
	var ids: Array[int] = []
	for i in count:
		var unit_id := first_unit_id + i
		units.append(_probe_unit(unit_id, side, anchor, speed))
		ids.append(unit_id)
	var existing := simulator.units
	existing.append_array(units)
	simulator.add_units(existing)

	var formation := BattleFormation.create(
		id, side, anchor, facing, "line", FormationCatalog.load_from(), _config())
	simulator.add_formation(formation)
	simulator.assign_formation(formation, ids)
	_dress(simulator, formation)
	return formation


func _dress(simulator: BattleSimulator, formation: BattleFormation) -> void:
	formation.ensure_slots()
	for i in formation.unit_ids.size():
		var unit := simulator.find_unit(formation.unit_ids[i])
		if unit != null:
			unit.position = formation.slots[i]
	# The men are where the body says they are, so the body's own summary of them is true now:
	# the station rule reads that summary rather than the roll (D-104), and a fixture that reads
	# a station before any summary exists would be reading no ranks at all.
	simulator.call("_refresh_summaries")


## A pair of bodies facing each other, close enough to reach each other without a walk.
func _opposed(
	seed_value: int,
	count: int = 20,
	separation: float = 6.0
) -> Dictionary:
	var simulator := BattleSimulator.new(_config(), seed_value)
	var ours := _add_body(simulator, "ours", SIDE_PLAYER, Vector2(40.0, 30.0), 0.0, count, 0)
	var field_mid := 40.0 + separation
	var theirs := _add_body(
		simulator, "theirs", SIDE_ENEMY, Vector2(field_mid, 30.0), PI, count, 100)
	simulator.start()
	return {"simulator": simulator, "ours": ours, "theirs": theirs}


## Kill every soldier standing in one rank of a body - the shape casualties leave behind.
## Casualties stay on the roll on purpose, so this is exactly what a battle does to itself
## over its first few hundred ticks, produced in one call. Rank 0 is the front rank.
func _kill_rank(simulator: BattleSimulator, body: BattleFormation, rank: int) -> int:
	var files := maxi(1, body.file_count)
	var killed := 0
	for i in body.unit_ids.size():
		if i / files != rank:
			continue
		var unit := simulator.find_unit(body.unit_ids[i])
		if unit != null and unit.is_alive():
			unit.take_damage(999999, -1)
			killed += 1
	return killed


func _kill_front_rank(simulator: BattleSimulator, body: BattleFormation) -> int:
	return _kill_rank(simulator, body, 0)


## The forward-most living soldier of a body, which is where its fighting front actually is.
func _living_front(simulator: BattleSimulator, body: BattleFormation) -> BattleUnit:
	var best: BattleUnit = null
	var best_projection := -INF
	var forward := body.forward()
	for unit_id in body.unit_ids:
		var unit := simulator.find_unit(unit_id)
		if unit == null or not unit.is_alive():
			continue
		var projection := (unit.position - body.anchor).dot(forward)
		if projection > best_projection:
			best_projection = projection
			best = unit
	return best


## Every living soldier of a body, in slot order.
func _living(simulator: BattleSimulator, body: BattleFormation) -> Array[BattleUnit]:
	var out: Array[BattleUnit] = []
	for unit_id in body.unit_ids:
		var unit := simulator.find_unit(unit_id)
		if unit != null and unit.is_alive():
			out.append(unit)
	return out


## Drive a battle the way the scene does: think above the soldiers, then step.
func _drive(
	simulator: BattleSimulator,
	ticks: int,
	hits: PackedInt32Array = PackedInt32Array()
) -> Dictionary:
	var config := _config()
	var ai_player := BattleAI.create(config, SIDE_PLAYER)
	var ai_enemy := BattleAI.create(config, SIDE_ENEMY)
	var ran := 0
	var hit_count := 0
	for i in ticks:
		if simulator.is_finished():
			break
		ai_player.update(simulator, STEP)
		ai_enemy.update(simulator, STEP)
		for event in simulator.step(STEP):
			if str(event.get("type", "")) == "hit":
				hit_count += 1
				if not hits.is_empty():
					hits.append(simulator.tick_index)
		ran += 1
	return {"ticks": ran, "hits": hit_count}


## A stable digest of a whole battle state: the clock, the outcome, and every soldier's
## health and position. Two runs that agree on this are the same battle.
func _fingerprint(simulator: BattleSimulator) -> String:
	var parts := PackedStringArray()
	parts.append("tick:%d" % simulator.tick_index)
	parts.append("elapsed:%.6f" % simulator.elapsed)
	parts.append("state:%d" % simulator.state)
	parts.append("winner:%s" % simulator.winner)
	var alive := 0
	for unit in simulator.units:
		if unit.is_alive():
			alive += 1
		parts.append("%d:%d:%.6f:%.6f" % [unit.id, unit.hp, unit.position.x, unit.position.y])
	parts.append("alive:%d" % alive)
	var joined := "|".join(parts)
	return "%08x" % (hash(joined) & 0xFFFFFFFF)


## ---------- the station ---------------------------------------------------

## Nothing about an un-fought battle changes. Two intact bodies stand off exactly as far as
## they did before: the station is measured over the ranks they still have, and both of them
## still have all of theirs.
func _test_an_intact_line_stops_where_it_always_did() -> void:
	section("an intact line stops where the depth rule put it")
	var bundle := _opposed(4242, 20, 8.0)
	var simulator: BattleSimulator = bundle["simulator"]
	var ours: BattleFormation = bundle["ours"]
	var theirs: BattleFormation = bundle["theirs"]

	var station: Vector2 = simulator.call("_engage_target_for", ours)
	var stand_off := theirs.anchor.distance_to(station) - _contact_gap()
	var depth_rule := (ours.depth() + theirs.depth()) * 0.5
	greater(depth_rule, 0.0, "the bodies have depth to speak of")
	approx(stand_off, depth_rule, 0.05,
		"the stand-off is still the two bodies' own depths (%.3f vs %.3f)" % [stand_off, depth_rule])
	# And that is the front rank's own place: the men who will do the fighting are the ones
	# the station puts in reach.
	approx(depth_rule, _spacing(), 0.05, "which for two two-rank lines is one spacing each")


## Casualties move the station. A rank that has been killed is not a front, so the body has
## to walk its next rank into the enemy to keep fighting - one rank for the rank it lost.
func _test_the_station_follows_the_surviving_front() -> void:
	section("a killed rank moves the station forward by a rank")
	var bundle := _opposed(4243, 40, 16.0)
	var simulator: BattleSimulator = bundle["simulator"]
	var ours: BattleFormation = bundle["ours"]
	var theirs: BattleFormation = bundle["theirs"]
	approx(float(ours.rank_count), 4.0, 0.001, "the bodies are four ranks deep, so ranks are left to lose")

	var intact := theirs.anchor.distance_to(simulator.call("_engage_target_for", ours))

	# One body loses its front rank: the station moves in by exactly one spacing. The summary
	# the rule reads is rebuilt once a tick from the soldiers themselves, so a test that has
	# just killed a rank says so explicitly rather than relying on a step it did not take.
	var killed := _kill_rank(simulator, ours, 0)
	simulator.call("_refresh_summaries")
	equal(killed, ours.file_count, "the whole front rank of the first body was killed")
	var wounded := theirs.anchor.distance_to(simulator.call("_engage_target_for", ours))
	approx(intact - wounded, _spacing(), 0.05,
		"the station moved forward by the rank that was lost (%.3f units)" % [intact - wounded])

	# Both bodies lose it: once more by exactly one spacing. What is left of each body is
	# standing where its own dead stood, and it is that front the station is measured from.
	_kill_rank(simulator, theirs, 0)
	simulator.call("_refresh_summaries")
	var both := theirs.anchor.distance_to(simulator.call("_engage_target_for", ours))
	approx(wounded - both, _spacing(), 0.05, "and again when the enemy loses its own")

	# Two ranks gone on both sides: the survivors are behind their own centres, so the station
	# is the clamp - as close as a body is ever allowed to put its centre, which is the
	# contact gap short of the enemy's. What finishes the reconnect from there is the soldiers
	# pressing forward, which is the next test's business. See D-101.
	_kill_rank(simulator, ours, 1)
	_kill_rank(simulator, theirs, 1)
	simulator.call("_refresh_summaries")
	var stripped := theirs.anchor.distance_to(simulator.call("_engage_target_for", ours))
	approx(stripped, _contact_gap(), 0.05,
		"and with the survivors behind their centres the station is the contact gap itself (%.3f units)" % stripped)
	greater(stripped, 0.0, "which is in front of the enemy's centre, never inside it")


## The state the frozen battle ended in: two centres driven onto each other until their
## surviving ranks stood one lattice apart, just outside every reach, with nothing able to
## close. A body never steers inside the enemy, so it cannot happen.
func _test_centres_never_converge() -> void:
	section("two engaging centres never drive into each other")
	var bundle := _opposed(5150, 20, 6.0)
	var simulator: BattleSimulator = bundle["simulator"]
	var ours: BattleFormation = bundle["ours"]
	var theirs: BattleFormation = bundle["theirs"]

	# Start close enough to touch, then take the front ranks away so the bodies have every
	# reason to keep closing - and hold one another's anchors through it.
	_kill_front_rank(simulator, ours)
	_kill_front_rank(simulator, theirs)
	ours.order_engage()
	theirs.order_engage()

	var closest := INF
	var closest_at := -1
	var stations_inside := 0
	for tick in 600:
		simulator.step(STEP)
		var apart := ours.anchor.distance_to(theirs.anchor)
		if apart < closest:
			closest = apart
			closest_at = simulator.tick_index
		var station: Vector2 = simulator.call("_engage_target_for", ours)
		if theirs.anchor.distance_to(station) < _contact_gap() - 0.001:
			stations_inside += 1

	equal(stations_inside, 0, "no station was ever placed inside the enemy's centre")
	greater(closest, _contact_gap() - 0.05,
		"and the two centres never came closer than the contact gap (%.3f units at tick %d)" % [
			closest, closest_at])


## The regression itself, in miniature: casualties open the ranks, and the fighting starts
## again rather than stopping for ever.
func _test_a_thinned_line_keeps_fighting() -> void:
	section("a line whose ranks have been killed keeps fighting")
	var bundle := _opposed(6161, 20, 8.0)
	var simulator: BattleSimulator = bundle["simulator"]
	var ours: BattleFormation = bundle["ours"]
	var theirs: BattleFormation = bundle["theirs"]
	ours.order_engage()
	theirs.order_engage()

	var reached := -1
	for tick in 400:
		simulator.step(STEP)
		if ours.in_contact and theirs.in_contact:
			reached = simulator.tick_index
			break
	greater(float(reached), 0.0, "the two bodies reached contact under their own orders")

	# The shape the 300 v 300 froze in: the front rank of both lines killed outright, so
	# every survivor's nearest enemy is a rank away.
	var killed := _kill_front_rank(simulator, ours) + _kill_front_rank(simulator, theirs)
	greater(float(killed), 8.0, "both front ranks were killed (%d soldiers)" % killed)
	simulator.step(STEP)
	equal(ours.in_contact or theirs.in_contact, false,
		"which takes both bodies out of contact - nobody can reach anybody")
	var opened_at := simulator.tick_index

	# The fighting has to come back on its own, and it has to stay back.
	var first_hit := -1
	var hits := 0
	var contact_ticks := 0
	var closest_centres := INF
	for tick in 1500:
		simulator.step(STEP)
		for event in simulator.events:
			if str(event.get("type", "")) == "hit":
				hits += 1
				if first_hit < 0:
					first_hit = simulator.tick_index
		if ours.in_contact or theirs.in_contact:
			contact_ticks += 1
		closest_centres = minf(closest_centres, ours.anchor.distance_to(theirs.anchor))

	greater(float(hits), 0.0, "the fighting restarted after the ranks were opened")
	greater(float(first_hit), 0.0, "with a blow struck again at tick %d" % first_hit)
	less(float(first_hit - opened_at), 400.0,
		"and it restarted promptly rather than after a battle's worth of standing about")
	greater(float(contact_ticks), 100.0,
		"contact has been held since (%d of 1500 ticks)" % contact_ticks)
	greater(closest_centres, _contact_gap() - 0.05,
		"and the two centres never sank into each other (closest %.2f units)" % closest_centres)


func _test_pressing_follows_contact() -> void:
	section("soldiers press forward when the line has stopped, and stop when it has not")
	var bundle := _opposed(7171, 20, 8.0)
	var simulator: BattleSimulator = bundle["simulator"]
	var ours: BattleFormation = bundle["ours"]
	var theirs: BattleFormation = bundle["theirs"]
	ours.order_engage()
	theirs.order_engage()
	simulator.call("_refresh_focus")

	var pressed_while_fighting := 0
	for tick in 400:
		simulator.step(STEP)
		if ours.in_contact:
			pressed_while_fighting += _pressers(simulator, ours)
	equal(pressed_while_fighting, 0,
		"nobody left the line while the line was fighting")

	# Take the front rank away: the body is at its station with nothing in reach, which is
	# the case the press-forward rule exists for.
	_kill_front_rank(simulator, ours)
	_kill_front_rank(simulator, theirs)
	for tick in 400:
		simulator.step(STEP)
		simulator.call("_refresh_focus")
		if _pressers(simulator, ours) > 0:
			break
	check(_pressers(simulator, ours) > 0,
		"with the fight stopped at their front, survivors are allowed to press forward")
	# ... and once contact is back, they are not.
	for tick in 600:
		simulator.step(STEP)
		if ours.in_contact:
			break
	equal(_pressers(simulator, ours), 0,
		"and the permission ends the moment the line is in contact again")


## The lock the frozen battle sat in: a body one unrepresentable step short of its station,
## reporting itself moving for the rest of the battle. The step is below what a single
## precision centre can express at that coordinate, so it is an arrival.
func _test_an_unexpressible_step_is_an_arrival() -> void:
	section("a step the centre cannot express is an arrival")
	var formation := BattleFormation.create(
		"locked", SIDE_PLAYER, Vector2(104.55005645752, 20.6), 0.0, "line",
		FormationCatalog.load_from(), _config())
	formation.order_engage()
	formation.steer_toward(Vector2(104.600059509277, 20.6))

	var gap := formation.anchor.distance_to(formation.target_anchor)
	greater(gap, 0.05, "the body is a hair outside its arrive radius (%.9f units)" % gap)
	equal(formation.is_moving(), true, "so it reports itself moving")

	var before := formation.anchor
	formation.advance(STEP, 3.51)

	equal(formation.is_moving(), false, "after a step it has arrived instead of moving for ever")
	less(before.distance_to(formation.anchor), 0.06,
		"and arriving moved it less than its own arrive radius - nothing was teleported")


func _pressers(simulator: BattleSimulator, body: BattleFormation) -> int:
	var allowed := 0
	for unit_id in body.unit_ids:
		var unit := simulator.find_unit(unit_id)
		if unit == null or not unit.is_alive():
			continue
		if bool(simulator.call("_can_press_forward", unit, body)):
			allowed += 1
	return allowed


## ---------- orders --------------------------------------------------------

## A body told to hold holds. It does not chase, it does not press forward, and it does not
## drift: the whole point of the reconnect behaviour is that it belongs to an order that
## asked for it.
func _test_hold_still_holds() -> void:
	section("hold is still hold")
	var simulator := BattleSimulator.new(_config(), 8181)
	var ours := _add_body(simulator, "ours", SIDE_PLAYER, Vector2(40.0, 30.0), 0.0, 20, 0)
	var theirs := _add_body(simulator, "theirs", SIDE_ENEMY, Vector2(46.0, 30.0), PI, 20, 100)
	ours.order_hold()
	theirs.order_hold()
	simulator.start()
	var anchor_before := ours.anchor
	var pressers := 0
	for tick in 200:
		simulator.step(STEP)
		pressers += _pressers(simulator, ours)
	approx(ours.anchor.distance_to(anchor_before), 0.0, 0.0001,
		"a held body's centre never moved")
	equal(pressers, 0, "and none of its soldiers were ever allowed to press forward")


## An engaged body that has nobody in contact closes until it has somebody in contact.
func _test_an_engaged_body_closes_and_reconnects() -> void:
	section("an engaged body with no contact closes the gap")
	var simulator := BattleSimulator.new(_config(), 8282)
	var ours := _add_body(simulator, "ours", SIDE_PLAYER, Vector2(20.0, 30.0), 0.0, 20, 0)
	var theirs := _add_body(simulator, "theirs", SIDE_ENEMY, Vector2(80.0, 30.0), PI, 20, 100)
	ours.order_engage()
	theirs.order_engage()
	simulator.start()

	var before := ours.anchor.distance_to(theirs.anchor)
	var reached := -1
	for tick in 1200:
		simulator.step(STEP)
		if ours.in_contact and theirs.in_contact:
			reached = simulator.tick_index
			break
	greater(before, 50.0, "the two bodies started most of a battlefield apart")
	greater(float(reached), 0.0, "and reached contact under their own orders")
	var after := ours.anchor.distance_to(theirs.anchor)
	less(after, before, "having closed the distance to do it (%.1f -> %.1f)" % [before, after])
	greater(after, _contact_gap() - 0.05,
		"without either centre being driven inside the other")


## A body with nobody left standing is not a body to steer at, and a body whose enemies are
## all dead stops.
func _test_a_wiped_body_is_not_pursued_for_ever() -> void:
	section("a wiped body is not chased, and the living one becomes the target")
	var simulator := BattleSimulator.new(_config(), 8383)
	var ours := _add_body(simulator, "ours", SIDE_PLAYER, Vector2(60.0, 30.0), 0.0, 20, 0)
	var near := _add_body(simulator, "theirs_near", SIDE_ENEMY, Vector2(70.0, 30.0), PI, 20, 100)
	var far := _add_body(simulator, "theirs_far", SIDE_ENEMY, Vector2(90.0, 30.0), PI, 20, 200)
	ours.order_engage()
	simulator.start()

	var first: BattleFormation = simulator.call("_nearest_enemy_formation", ours)
	equal(first, near, "the nearest body is the one being engaged")

	for unit_id in near.unit_ids:
		var unit := simulator.find_unit(unit_id)
		if unit != null:
			unit.take_damage(999999, -1)
	var second: BattleFormation = simulator.call("_nearest_enemy_formation", ours)
	equal(second, far, "wiping it moves the engagement to the body that is still standing")

	for unit_id in far.unit_ids:
		var unit := simulator.find_unit(unit_id)
		if unit != null:
			unit.take_damage(999999, -1)
	var none: BattleFormation = simulator.call("_nearest_enemy_formation", ours)
	is_null(none, "with nobody left there is nobody to engage")
	var station: Vector2 = simulator.call("_engage_target_for", ours)
	approx(station.distance_to(ours.anchor), 0.0, 0.0001,
		"and the body is given its own ground rather than a corpse to walk at")
	for tick in 100:
		simulator.step(STEP)
	approx(ours.anchor.distance_to(Vector2(60.0, 30.0)), 0.0, 0.0001,
		"so it stands where it was rather than marching at nothing")


## Contact belongs to a body. A wing that has not reached the enemy must still close while
## the centre is fighting - the old side-wide flag suppressed exactly this, and the fix for
## the stalemate must not bring it back.
func _test_contact_stays_formation_local() -> void:
	section("contact is still a fact about one body")
	var simulator := BattleSimulator.new(_config(), 8484)
	var centre_ours := _add_body(simulator, "centre_ours", SIDE_PLAYER, Vector2(20.0, 20.0), 0.0, 10, 0)
	var centre_theirs := _add_body(simulator, "centre_theirs", SIDE_ENEMY, Vector2(21.5, 20.0), PI, 10, 100)
	var wing_ours := _add_body(simulator, "wing_ours", SIDE_PLAYER, Vector2(60.0, 15.0), 0.0, 10, 200)
	var wing_theirs := _add_body(simulator, "wing_theirs", SIDE_ENEMY, Vector2(90.0, 15.0), PI, 10, 300)
	wing_ours.order_engage()
	simulator.start()
	for tick in 10:
		simulator.step(STEP)
	equal(centre_ours.in_contact, true, "the centre is fighting")
	equal(wing_ours.in_contact, false, "and the wing, which has not arrived, is not")

	var before := wing_ours.anchor.distance_to(wing_theirs.anchor)
	for tick in 200:
		simulator.step(STEP)
	var after := wing_ours.anchor.distance_to(wing_theirs.anchor)
	less(after, before - 1.0,
		"the wing still closed on its own opposite number (%.1f -> %.1f)" % [before, after])
	equal(centre_ours.in_contact, true, "while the centre kept fighting")


## ---------- determinism ---------------------------------------------------

## Same seed, same orders, same steps: same battle, twice over.
func _test_same_seed_same_battle() -> void:
	section("the same seed fights the same battle")
	var first := _small_battle(SHOWCASE_SEED + 5)
	var second := _small_battle(SHOWCASE_SEED + 5)
	var first_print := _fingerprint(first["simulator"])
	var second_print := _fingerprint(second["simulator"])
	equal(first_print, second_print, "two runs of one seed agree soldier for soldier")
	greater(float(first["hits"]), 0.0, "and the battle was fought rather than skipped")
	equal(int(first["living"]), int(second["living"]), "with the same number left standing")


## Frames in, whole ticks out. Pacing decides how many ticks a frame runs and nothing else:
## not the size of a tick, and not the battle.
func _test_frame_pacing_does_not_change_a_battle() -> void:
	section("frame pacing does not change a battle")
	var clock := BattleClock.create(_config())
	approx(clock.step, STEP, 0.0001, "the fixed step comes from the battle data")
	approx(clock.rate(), 20.0, 0.001, "and the data's rate is the rate the design is measured at")

	# The same real time, fed in as many small frames and as a few large ones.
	var many := BattleClock.create(_config())
	var few := BattleClock.create(_config())
	var many_ticks := 0
	var few_ticks := 0
	for i in 240:
		many_ticks += many.frame(1.0 / 60.0)
	for i in 60:
		few_ticks += few.frame(1.0 / 15.0)
	approx(float(many_ticks), float(few_ticks), 1.0,
		"the same four seconds of real time buys the same ticks (60 fps: %d, 15 fps: %d)" % [many_ticks, few_ticks])
	approx(many.step, few.step, 0.0001, "at one step size")

	# A speed multiplier buys more ticks per frame, not a longer tick.
	var fast := BattleClock.create(_config())
	var fast_ticks := 0
	for i in 240:
		fast_ticks += fast.frame(1.0 / 60.0, 4.0)
	approx(float(fast_ticks), float(many_ticks) * 4.0, 4.0,
		"four times the battle speed is four times the ticks, not four times the step (%d vs %d)" % [
			fast_ticks, many_ticks * 4])
	approx(fast.step, STEP, 0.0001, "and the step is untouched by it")

	# And the battle itself: the same run, paced two different ways, compared at the same
	# tick rather than at the same wall clock.
	var smooth := _paced_battle(SHOWCASE_SEED + 6, 0.0166, 900)
	var stuttering := _paced_battle(SHOWCASE_SEED + 6, 0.05, 900)
	equal(String(smooth["fingerprint"]), String(stuttering["fingerprint"]),
		"a 60 fps run and a 20 fps run reach the same state at the same tick")
	equal(int(smooth["ticks"]), int(stuttering["ticks"]), "after the same number of ticks")
	approx(float(smooth["elapsed"]), float(stuttering["elapsed"]), 0.0001,
		"and therefore the same simulated time")


## ---------- the headline case ---------------------------------------------

## Three hundred a side, three bodies each, the showcase's own seed and layout: the battle
## that froze at half casualties must reach a result. This is the suite's slowest test and
## the one the milestone is judged on.
func _test_three_hundred_a_side_resolves() -> void:
	section("three hundred a side reaches a result")
	var config := _config()
	# No clock worth the name: the battle is given an hour of battle time and has to reach a
	# result by fighting. The production clock would end it at six hundred seconds, and the
	# test below is the one that measures what happens there.
	var boot := ShowcaseBattle.build(
		config, UnitCatalog.load_from(), FormationCatalog.load_from(), 300, SHOWCASE_SEED,
		"spearman", "spearman", 3600.0)
	var simulator: BattleSimulator = boot["simulator"]
	simulator.start()
	var ai_player := BattleAI.create(config, SIDE_PLAYER)
	var ai_enemy := BattleAI.create(config, SIDE_ENEMY)

	var limit := 24000
	var previous: Dictionary = {}
	var last_hit := 0
	var longest_quiet := 0
	var worst_position_error := 0
	var worst_move := 0.0
	var move_bound := 0.0
	var ticks := 0
	while ticks < limit and not simulator.is_finished():
		ai_player.update(simulator, STEP)
		ai_enemy.update(simulator, STEP)
		for event in simulator.step(STEP):
			if str(event.get("type", "")) == "hit":
				last_hit = simulator.tick_index
		ticks += 1
		var both_alive := simulator.side_count(SIDE_PLAYER) > 0 \
			and simulator.side_count(SIDE_ENEMY) > 0
		if both_alive and simulator.tick_index - last_hit > longest_quiet:
			longest_quiet = simulator.tick_index - last_hit
		if simulator.tick_index % 20 == 0:
			move_bound = 20.0 * (5.6 * STEP + 1.35)
			for unit in simulator.units:
				if not unit.is_alive():
					continue
				if not (is_finite(unit.position.x) and is_finite(unit.position.y)):
					worst_position_error += 1
				var previous_position: Variant = previous.get(unit.id)
				if previous_position != null:
					worst_move = maxf(worst_move, unit.position.distance_to(previous_position as Vector2))
				previous[unit.id] = unit.position

	check(simulator.is_finished(), "the battle reached a result within %d ticks" % limit)
	equal(simulator.is_finished(), true,
		"rather than standing there: %d player and %d enemy still up at tick %d" % [
			simulator.side_count(SIDE_PLAYER), simulator.side_count(SIDE_ENEMY), simulator.tick_index])
	not_equal(simulator.winner, "", "a side won it")
	less(simulator.elapsed, simulator.max_duration,
		"and the fighting decided it rather than the clock: %.1fs of battle time" % simulator.elapsed)
	less(float(longest_quiet), 600.0,
		"and the longest stretch with both armies alive and nobody struck a blow was %.0f ticks" % longest_quiet)
	equal(worst_position_error, 0, "no soldier ever had a position that was not a number")
	less(worst_move, move_bound,
		"and nobody crossed the field in a tick: worst movement in a twenty-tick window was %.2f units" % worst_move)

	# The physical invariants the fix must not have traded away for a result.
	var living := 0
	var closest := INF
	var field := simulator.field_size
	for unit in simulator.units:
		if not unit.is_alive():
			continue
		living += 1
		less(unit.position.x, field.x + 1.0, "a survivor is on the field")
		greater(unit.position.x, -1.0, "and not off the far side")
	greater(float(living), 0.0, "somebody survived the battle")
	var all: Array[BattleUnit] = simulator.alive_units()
	for i in all.size():
		for j in range(i + 1, all.size()):
			closest = minf(closest, all[i].position.distance_to(all[j].position))
	greater(closest, 0.6,
		"and nobody was standing inside anybody else (closest pair %.2f units)" % closest)


## The dev-only battle journal: it says what happened, and nothing opens one unless asked.
func _test_the_battle_journal_writes_the_transitions() -> void:
	section("the dev-only battle journal")
	var path := "user://test_battle_journal.log"
	var built := _opposed(4243, 40, 16.0)
	var simulator: BattleSimulator = built["simulator"]
	var journal := BattleJournal.open(path)
	not_null(journal, "a journal can be opened")
	journal.note_start(simulator, 4243)

	var ai_player := BattleAI.create(_config(), SIDE_PLAYER)
	var ai_enemy := BattleAI.create(_config(), SIDE_ENEMY)
	var ticks := 0
	while ticks < 4000 and not simulator.is_finished():
		ai_player.update(simulator, STEP)
		ai_enemy.update(simulator, STEP)
		simulator.step(STEP)
		journal.observe(simulator)
		ticks += 1
	journal.close()
	greater(float(journal.lines_written()), 4.0, "and it wrote lines")

	var text := FileAccess.get_file_as_string(path)
	check(text.contains("battle start: seed 4243"), "the file says which battle it describes")
	check(text.contains("contact"), "and records contact being gained")
	check(text.contains("down:"), "and the casualty milestones")
	check(text.contains("finished:") or text.contains("clock expired"),
		"and says how the battle ended")
	check(text.contains("still fighting"), "and keeps saying where the battle stands")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## The production battle clock is six hundred seconds. The brief's complaint was that this clock
## *hid* the stalemate: an army stopped fighting at half strength and the timer ended the battle.
## The property that matters is not that the clock never expires - it is what it interrupts. Run
## the same battle under the real clock and require that both armies are still on the field, that
## they were still trading blows when it ended, and that no silence in the whole battle came near
## the fifteen thousand ticks the unfixed build spent with nobody able to reach anybody.
func _test_the_production_clock_ends_a_live_fight() -> void:
	section("the production clock ends a live fight, not a freeze")
	var config := _config()
	var boot := ShowcaseBattle.build(
		config, UnitCatalog.load_from(), FormationCatalog.load_from(), 300, SHOWCASE_SEED)
	var simulator: BattleSimulator = boot["simulator"]
	equal(simulator.max_duration, 600.0, "the production clock is six hundred seconds")
	simulator.start()
	var ai_player := BattleAI.create(config, SIDE_PLAYER)
	var ai_enemy := BattleAI.create(config, SIDE_ENEMY)

	var last_hit := 0
	var quiet_from := 0
	var longest_quiet := 0
	while not simulator.is_finished():
		ai_player.update(simulator, STEP)
		ai_enemy.update(simulator, STEP)
		for event in simulator.step(STEP):
			if str(event.get("type", "")) == "hit":
				last_hit = simulator.tick_index
				quiet_from = simulator.tick_index
		var both_alive := simulator.side_count(SIDE_PLAYER) > 0 \
			and simulator.side_count(SIDE_ENEMY) > 0
		if both_alive and simulator.tick_index - quiet_from > longest_quiet:
			longest_quiet = simulator.tick_index - quiet_from

	check(simulator.is_finished(), "the clock ends this battle at six hundred seconds of battle")
	equal(simulator.winner, "", "and it ends it undecided, with both armies on the field: %d v %d" % [
		simulator.side_count(SIDE_PLAYER), simulator.side_count(SIDE_ENEMY)])
	greater(float(simulator.side_count(SIDE_PLAYER)), 0.0, "the players are still there")
	greater(float(simulator.side_count(SIDE_ENEMY)), 0.0, "and so are the enemy")
	less(float(simulator.tick_index - last_hit), 120.0,
		"and they were still fighting when it ended: the last blow landed %d ticks before the cut" % (simulator.tick_index - last_hit))
	less(float(longest_quiet), 600.0,
		"and no stretch of the battle went quiet for even ten seconds: the worst was %.0f ticks" % longest_quiet)


## ---------- fixtures for the determinism tests ----------------------------

## A small battle of the showcase's own shape, driven to a fixed tick count with a digest.
func _small_battle(seed_value: int) -> Dictionary:
	var boot := ShowcaseBattle.build(
		_config(), UnitCatalog.load_from(), FormationCatalog.load_from(), 60, seed_value)
	var simulator: BattleSimulator = boot["simulator"]
	simulator.start()
	var stats := _drive(simulator, 1500)
	var living := 0
	for unit in simulator.units:
		if unit.is_alive():
			living += 1
	return {
		"simulator": simulator,
		"hits": stats["hits"],
		"living": living,
	}


## One battle driven through the clock at a fixed frame length, stopped after
## [param tick_limit] simulation ticks. What the frame length was should not matter; only
## how many ticks were run.
func _paced_battle(seed_value: int, frame_delta: float, tick_limit: int) -> Dictionary:
	var config := _config()
	var boot := ShowcaseBattle.build(
		config, UnitCatalog.load_from(), FormationCatalog.load_from(), 60, seed_value)
	var simulator: BattleSimulator = boot["simulator"]
	var clock := BattleClock.create(config)
	var ai_player := BattleAI.create(config, SIDE_PLAYER)
	var ai_enemy := BattleAI.create(config, SIDE_ENEMY)
	simulator.start()
	while simulator.tick_index < tick_limit and not simulator.is_finished():
		var due := clock.frame(frame_delta)
		for i in due:
			if simulator.tick_index >= tick_limit or simulator.is_finished():
				break
			ai_player.update(simulator, clock.step)
			ai_enemy.update(simulator, clock.step)
			simulator.step(clock.step)
	return {
		"fingerprint": _fingerprint(simulator),
		"ticks": simulator.tick_index,
		"elapsed": simulator.elapsed,
	}
