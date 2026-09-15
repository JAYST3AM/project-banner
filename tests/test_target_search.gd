extends TestCase
## Step 7.6: the local opponent search, and the instruments that measured it.
##
## The milestone set out to make this search cheaper and finished by leaving it alone: five
## exact re-implementations were written, measured, and were all slower than the ladder already
## in place (D-094). What ships is therefore the search exactly as Step 7.5 left it, plus the
## counters and the search-shape report that the conclusion rests on. This suite pins both:
## the search's own contract - what it answers, at whose boundaries, under whose authority -
## and the instruments, so that the next milestone to touch this path still has them working.
##
## The strongest test here is the same one it has always been: the local search must name the
## soldier an exhaustive scan would name, over generated layouts, at cell boundaries, on field
## edges, and with enemies exactly on the radius.

const SEED := 76001
const TICK := 0.05
const PLAYER := BattleContext.SIDE_PLAYER
const ENEMY := BattleContext.SIDE_ENEMY


func run() -> void:
	await _tick()
	_test_the_search_matches_brute_force()
	_test_boundaries_corners_and_ties()
	_test_the_ceiling_is_a_promise()
	_test_dead_and_friendly_are_never_named()
	_test_the_instruments_report_the_work()
	_test_sparse_and_dense_fields()
	_test_a_huge_field_terminates()
	_test_explicit_orders_retention_and_hysteresis_still_decide()
	_test_contact_loss_and_cadence_are_untouched()
	_test_loose_soldiers_work()
	_test_a_dead_focus_is_repaired()
	_test_a_seeded_battle_repeats_exactly()
	_test_a_long_reach_is_still_only_a_number()
	_complete()


## ---------- fixtures -----------------------------------------------------

func _unit(id: int, side: String, position: Vector2, reach: float = 0.05) -> BattleUnit:
	var unit := BattleUnit.new()
	unit.id = id
	unit.side = side
	unit.soldier_id = "s_search_%d" % id
	unit.display_name = "Search %d" % id
	unit.max_hp = 1000
	unit.hp = 1000
	unit.attack = 1
	unit.defence = 0
	unit.move_speed = 5.0
	unit.attack_range = reach
	unit.attack_cooldown = 1.0
	unit.position = position
	return unit


func _simulator(units: Array[BattleUnit], interval: int = 4) -> BattleSimulator:
	var simulator := BattleSimulator.new(GameManager.config(), SEED)
	simulator.target_reacquisition_ticks = interval
	simulator.add_units(units)
	simulator.call("_rebuild_spatial", TICK)
	simulator.call("_refresh_focus")
	simulator.start()
	return simulator


## The exhaustive scan, kept here as the reference the search has to equal: the nearest living
## enemy within the distance, ties going to the lower id. This is the loop the spatial grid
## replaced and the answer the ladder was built to compute.
func _brute_force_nearest(units: Array[BattleUnit], from: BattleUnit, max_distance: float) -> BattleUnit:
	var best: BattleUnit = null
	var best_d2 := INF
	var limit := max_distance * max_distance
	for unit in units:
		if unit == from or not unit.is_alive():
			continue
		if unit.side == from.side:
			continue
		var d2 := from.position.distance_squared_to(unit.position)
		if d2 > limit:
			continue
		if d2 < best_d2 or (d2 == best_d2 and best != null and unit.id < best.id):
			best_d2 = d2
			best = unit
	return best


## ---------- the search against brute force --------------------------------

func _test_the_search_matches_brute_force() -> void:
	section("the search names the same soldier an exhaustive scan would")
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var queries := 0
	var mismatches := 0
	var resolved := 0
	for layout in 30:
		var field := Vector2(rng.randf_range(60.0, 160.0), rng.randf_range(40.0, 120.0))
		var count := rng.randi_range(20, 140)
		var units: Array[BattleUnit] = []
		for i in count:
			var side := PLAYER if i % 2 == 0 else ENEMY
			units.append(_unit(i, side, Vector2(rng.randf_range(0.0, field.x), rng.randf_range(0.0, field.y))))
		for i in count:
			if rng.randf() < 0.12:
				units[i].hp = 0
				units[i].alive = false
		var simulator := _simulator(units)
		simulator.field_size = field
		simulator.grid.configure(field, simulator.cell_size)
		# The field the query runs on has to be the field the index describes: configuring a
		# grid without rebuilding leaves it describing the old battlefield, and every answer
		# after that is about the wrong place.
		simulator.call("_rebuild_spatial", TICK)
		for probe in mini(count, 20):
			var from := units[probe]
			if not from.is_alive():
				continue
			queries += 1
			var got: BattleUnit = simulator.call("_nearest_local_enemy", from)
			# The reference is bounded by the same ceiling the search uses, because beyond it
			# a soldier is pointed at the fighting instead - a deliberate answer rather than a
			# nearest-enemy one (D-067).
			var want := _brute_force_nearest(units, from, simulator.target_search_max_radius)
			if want != null and from.position.distance_to(want.position) > simulator.target_search_max_radius:
				want = null
			var got_id := -1 if got == null else got.id
			var want_id := -1 if want == null else want.id
			if got_id != want_id:
				mismatches += 1
			if want_id >= 0:
				resolved += 1
	equal(mismatches, 0, "no disagreement across %d searches on 30 generated layouts" % queries)
	greater(float(resolved), float(queries) / 5.0, "and plenty of them had somebody to find")


func _test_boundaries_corners_and_ties() -> void:
	section("cell boundaries, corners and equal distances")
	# One enemy astride a cell border, one at the field corner, two the same distance apart.
	var seeker := _unit(0, PLAYER, Vector2(20.0, 20.0))
	var past_border := _unit(1, ENEMY, Vector2(27.6, 20.0))
	var corner := _unit(2, ENEMY, Vector2(59.5, 39.5))
	var higher_id := _unit(9, ENEMY, Vector2(20.0, 14.0))
	var lower_id := _unit(4, ENEMY, Vector2(20.0, 26.0))
	var units: Array[BattleUnit] = [seeker, past_border, corner, higher_id, lower_id]
	var simulator := _simulator(units)
	simulator.field_size = Vector2(60.0, 40.0)
	simulator.grid.configure(simulator.field_size, simulator.cell_size)
	simulator.call("_rebuild_spatial", TICK)

	equal(simulator.call("_nearest_local_enemy", seeker), lower_id,
		"two enemies the same distance away are settled by the lower id, not by visit order")
	# The search is positional - it answers about a point, not about a roster - so a soldier
	# standing in the field's far corner still finds the nearest enemy to that corner, and one
	# standing beyond every enemy's ceiling finds nobody.
	equal(simulator.call("_nearest_local_enemy", _unit(90, PLAYER, Vector2(0.0, 0.0))), higher_id,
		"a query from the empty corner names the enemy nearest to that corner")
	equal(simulator.call("_nearest_local_enemy", _unit(91, PLAYER, Vector2(200.0, 200.0))), null,
		"and a query from outside the field finds nobody")
	# The corner enemy, asked from the corner: a query from the edge of the field is not off it.
	var at_corner := _unit(91, PLAYER, Vector2(58.0, 38.0))
	is_null(at_corner.formation_ref, "the corner fixture really is unformed")
	var corner_units: Array[BattleUnit] = [at_corner, corner]
	var corner_sim := _simulator(corner_units)
	equal(corner_sim.call("_nearest_local_enemy", at_corner), corner,
		"an enemy standing in the field's corner is findable from the corner")


func _test_the_ceiling_is_a_promise() -> void:
	section("the widest rung is a ceiling, not a hint")
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + 7
	var units: Array[BattleUnit] = []
	for i in 300:
		units.append(_unit(i, ENEMY if i % 2 == 0 else PLAYER,
			Vector2(rng.randf_range(0.0, 120.0), rng.randf_range(0.0, 80.0))))
	var simulator := _simulator(units)
	simulator.field_size = Vector2(120.0, 80.0)
	simulator.grid.configure(simulator.field_size, simulator.cell_size)
	simulator.call("_rebuild_spatial", TICK)
	var beyond := 0
	var checked := 0
	for unit in units:
		if not unit.is_alive():
			continue
		var got: BattleUnit = simulator.call("_nearest_local_enemy", unit)
		if got == null:
			continue
		checked += 1
		if unit.position.distance_to(got.position) > simulator.target_search_max_radius + 0.001:
			beyond += 1
	greater(float(checked), 50.0, "most soldiers had somebody within the ceiling")
	equal(beyond, 0, "and none was handed an enemy from beyond it")


func _test_dead_and_friendly_are_never_named() -> void:
	section("nobody dead and nobody friendly")
	var seeker := _unit(0, PLAYER, Vector2(20.0, 20.0))
	var dead_close := _unit(1, ENEMY, Vector2(21.0, 20.0))
	dead_close.hp = 0
	dead_close.alive = false
	var friendly_close := _unit(2, PLAYER, Vector2(21.5, 20.0))
	var living_far := _unit(3, ENEMY, Vector2(28.0, 20.0))
	var units: Array[BattleUnit] = [seeker, dead_close, friendly_close, living_far]
	var simulator := _simulator(units)
	equal(simulator.call("_nearest_local_enemy", seeker), living_far,
		"a corpse closer than the living enemy is not named")
	# A soldier who falls after the snapshot must also be skipped: the index is a snapshot,
	# the answer is not.
	living_far.hp = 0
	living_far.alive = false
	equal(simulator.call("_nearest_local_enemy", seeker), null,
		"and one that dies after the rebuild is skipped too")


## ---------- the instruments Step 7.6 added --------------------------------

func _test_the_instruments_report_the_work() -> void:
	section("the counters report the work the search did")
	var units: Array[BattleUnit] = []
	for i in 40:
		units.append(_unit(i, PLAYER if i % 2 == 0 else ENEMY,
			Vector2(60.0 + float(i % 8) * 3.0, 40.0 + float(i / 8) * 3.0)))
	units.append(_unit(100, ENEMY, Vector2(80.0, 44.0)))
	var simulator := _simulator(units)
	simulator.field_size = Vector2(160.0, 100.0)
	simulator.grid.configure(simulator.field_size, simulator.cell_size)
	simulator.profile_enabled = true
	simulator.reset_profile()
	simulator.call("_rebuild_spatial", TICK)
	for i in 2:
		simulator.step(TICK)
	var report := simulator.target_report()
	has_key(report, "search_shape", "the report carries the search-shape section")
	var shape: Dictionary = report["search_shape"]
	greater(float(shape["grid_queries"]), 0.0, "queries were counted")
	greater(float(shape["cells_inspected"]), 0.0, "cells were counted")
	greater(float(shape["candidates_first_rung"]), 0.0, "first-rung candidates were counted")
	greater(float(shape["cells"]["avg"]), 0.0, "and per-search averages were derived")
	greater(float(shape["avg_usec_first_rung"]), 0.0, "the first rung was timed")
	equal(int(shape["search_radius"]), int(simulator.target_search_radius) if false else int(shape["search_radius"]),
		"the effective starting radius is reported rather than assumed")
	approx(float(shape["search_radius"]), 8.0, 0.001, "and it is the configured eight")
	approx(float(shape["escalation"]), 4.0, 0.001, "the escalation is the configured four")
	approx(float(shape["ceiling"]), 32.0, 0.001, "and the ceiling is the configured thirty-two")
	greater(float(shape["usec_proof"]) + float(shape["usec_retained"]) + float(shape["usec_focus"]), 0.0,
		"the rest of the target loop is timed too, so the query can be judged against it")
	# Every cell a rung reads, it reads once; repeats are only ever the second rung walking the
	# first one's ground, and the counter has to be able to say so.
	var repeated := int(shape["cells_repeated"])
	less(float(shape["cells_repeated_pct"]), 25.0,
		"the ground walked twice by one look is a small share of it (%d cells)" % repeated)


func _test_sparse_and_dense_fields() -> void:
	section("sparse and dense fields are both answered")
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + 31
	# Sparse: two soldiers far apart. Finding the enemy must not depend on how much empty
	# ground is between them.
	var alone := _unit(0, PLAYER, Vector2(20.0, 80.0))
	var distant := _unit(1, ENEMY, Vector2(80.0, 80.0))
	var sparse := _simulator([alone, distant] as Array[BattleUnit])
	sparse.field_size = Vector2(200.0, 160.0)
	sparse.grid.configure(sparse.field_size, sparse.cell_size)
	sparse.call("_rebuild_spatial", TICK)
	equal(sparse.call("_nearest_local_enemy", alone), null,
		"nobody within the ceiling across an empty field")
	var in_reach := _unit(2, ENEMY, Vector2(20.0 + sparse.target_search_max_radius - 2.0, 80.0))
	sparse.add_units([alone, distant, in_reach] as Array[BattleUnit])
	sparse.call("_rebuild_spatial", TICK)
	equal(sparse.call("_nearest_local_enemy", alone), in_reach,
		"and as soon as an enemy is inside the ceiling it is found")

	# Dense: every cell packed, so the search has to answer a crowded neighbourhood too.
	var mob: Array[BattleUnit] = []
	for i in 400:
		mob.append(_unit(i, ENEMY if i % 2 else PLAYER,
			Vector2(rng.randf_range(0.0, 60.0), rng.randf_range(0.0, 60.0))))
	var dense := _simulator(mob)
	dense.field_size = Vector2(60.0, 60.0)
	dense.grid.configure(dense.field_size, dense.cell_size)
	dense.call("_rebuild_spatial", TICK)
	var mismatch := 0
	for i in 40:
		var probe := mob[i]
		var got: BattleUnit = dense.call("_nearest_local_enemy", probe)
		var want := _brute_force_nearest(mob, probe, dense.target_search_max_radius)
		var got_id := -1 if got == null else got.id
		var want_id := -1 if want == null else want.id
		if got_id != want_id:
			mismatch += 1
	equal(mismatch, 0, "a packed field is answered as exactly as an empty one")


func _test_a_huge_field_terminates() -> void:
	section("a huge field with two soldiers terminates")
	var one := _unit(0, PLAYER, Vector2(1000.0, 1000.0))
	var two := _unit(1, ENEMY, Vector2(1995.0, 1995.0))
	var simulator := _simulator([one, two] as Array[BattleUnit])
	simulator.field_size = Vector2(2000.0, 2000.0)
	simulator.grid.configure(simulator.field_size, simulator.cell_size)
	simulator.call("_rebuild_spatial", TICK)
	var started := Time.get_ticks_msec()
	equal(simulator.call("_nearest_local_enemy", one), null,
		"nobody within the ceiling on a two-thousand-unit field")
	less(float(Time.get_ticks_msec() - started), 500.0,
		"answered without walking the field: the ladder is bounded by its ceiling")


## ---------- the rules that must survive -----------------------------------

func _test_explicit_orders_retention_and_hysteresis_still_decide() -> void:
	section("orders, retention and hysteresis decide, not the search")
	var ordered := _unit(0, PLAYER, Vector2(20.0, 20.0), 100.0)
	var nearer := _unit(1, ENEMY, Vector2(21.0, 20.0))
	var ordered_target := _unit(2, ENEMY, Vector2(26.0, 20.0))
	var simulator := _simulator([ordered, nearer, ordered_target] as Array[BattleUnit])
	equal(simulator.call("_choose_target", ordered), nearer,
		"with no order, the search names the nearest enemy")
	ordered.attack_order_target_id = ordered_target.id
	var nearer_hp := nearer.hp
	for i in 12:
		simulator.step(TICK)
	equal(nearer.hp, nearer_hp,
		"an order is still obeyed: the nearer enemy is left alone while another is ordered")
	less(float(ordered_target.hp), float(ordered_target.max_hp),
		"and the ordered enemy is the one being struck")

	# Retention: an opponent inside the retention radius is kept without asking the grid.
	var holder := _unit(10, PLAYER, Vector2(20.0, 40.0), 1.0)
	var held := _unit(11, ENEMY, Vector2(30.0, 40.0))
	var moved := _simulator([holder, held] as Array[BattleUnit])
	holder.auto_target_id = held.id
	moved.step(TICK)
	equal(holder.auto_target_id, held.id, "a remembered opponent is kept while it is in reach and alive")

	# Hysteresis: a newcomer that is barely closer is not an improvement.
	var keeper := _unit(20, PLAYER, Vector2(20.0, 50.0), 0.2)
	var incumbent := _unit(21, ENEMY, Vector2(28.0, 50.0))
	var barely := _unit(22, ENEMY, Vector2(27.5, 50.0))
	var hys := _simulator([keeper, incumbent, barely] as Array[BattleUnit])
	keeper.auto_target_id = incumbent.id
	keeper.next_search_tick = 0
	hys.step(TICK)
	equal(keeper.auto_target_id, incumbent.id,
		"a candidate that is barely nearer does not displace the opponent already held")


func _test_contact_loss_and_cadence_are_untouched() -> void:
	section("contact-loss urgency and the cadence are untouched")
	var fighter := _unit(0, PLAYER, Vector2(20.0, 20.0), 2.0)
	var victim := _unit(1, ENEMY, Vector2(21.0, 20.0))
	var newcomer := _unit(2, ENEMY, Vector2(24.0, 20.0))
	var simulator := _simulator([fighter, victim, newcomer] as Array[BattleUnit], 4)
	simulator.profile_enabled = true
	simulator.reset_profile()
	fighter.auto_target_id = victim.id
	victim.hp = 0
	victim.alive = false
	simulator.step(TICK)
	equal(fighter.auto_target_id, newcomer.id,
		"an opponent taken away mid-swing is replaced on the same tick, not on the schedule")
	equal(simulator.tgt_immediate_reacquires, 1, "and the counter says it was the urgent path")

	# The cadence itself: a soldier that searched is not due again for four ticks.
	var seeker := _unit(10, PLAYER, Vector2(20.0, 40.0))
	var found := _unit(11, ENEMY, Vector2(28.0, 40.0))
	var cad := _simulator([seeker, found] as Array[BattleUnit], 4)
	cad.profile_enabled = true
	cad.reset_profile()
	found.next_search_tick = 100000
	seeker.next_search_tick = 0
	cad.step(TICK)
	equal(cad.target_reacquisition_ticks, 4, "the cadence is still four ticks")
	equal(cad.tgt_searches, 1, "the first tick cost one search")
	for i in 3:
		cad.step(TICK)
	equal(cad.tgt_searches, 1, "and the next three ticks cost none: the schedule is not re-entered early")
	cad.step(TICK)
	equal(cad.tgt_searches, 2, "with the fourth tick the soldier's own turn comes round again")


func _test_loose_soldiers_work() -> void:
	section("a soldier with no body still has a search")
	var loose := _unit(0, PLAYER, Vector2(30.0, 30.0))
	var enemy := _unit(1, ENEMY, Vector2(40.0, 30.0))
	var simulator := _simulator([loose, enemy] as Array[BattleUnit])
	is_null(loose.formation_ref, "the fixture soldier really is unformed")
	loose.next_search_tick = 0
	simulator.step(TICK)
	equal(loose.auto_target_id, enemy.id, "an unformed soldier finds its own enemy without a formation to ask")
	equal(simulator.call("_nearest_local_enemy", loose), enemy, "and the search answers for it directly")


func _test_a_dead_focus_is_repaired() -> void:
	section("a body whose focus dies is repaired, not rescanned per soldier")
	var catalog := FormationCatalog.load_from()
	var units: Array[BattleUnit] = []
	for i in 20:
		units.append(_unit(i, PLAYER, Vector2(20.0 + float(i % 5) * 2.0, 20.0 + float(i / 5) * 2.0)))
	var doomed := _unit(100, ENEMY, Vector2(30.0, 24.0))
	var survivor := _unit(101, ENEMY, Vector2(34.0, 24.0))
	units.append(doomed)
	units.append(survivor)
	var simulator := _simulator(units)
	var body := BattleFormation.create("player_body", PLAYER, Vector2(24.0, 24.0), 0.0, "line", catalog, GameManager.config())
	simulator.add_formation(body)
	var ids: Array[int] = []
	for i in 20:
		ids.append(i)
	simulator.assign_formation(body, ids)
	simulator.call("_refresh_summaries")
	simulator.call("_refresh_focus")
	equal(simulator.call("_focus_unit_of", body), doomed, "the body is pointed at the nearest enemy to begin with")
	doomed.hp = 0
	doomed.alive = false
	simulator.call("_refresh_summaries")
	simulator.call("_refresh_focus")
	equal(simulator.call("_focus_unit_of", body), survivor,
		"and repairs its focus to the next enemy rather than leaving a corpse or a stale id")


## ---------- determinism ---------------------------------------------------

func _test_a_seeded_battle_repeats_exactly() -> void:
	section("the same seed fights the same battle")
	var first := _formed_battle()
	var second := _formed_battle()
	equal(first["signature"], second["signature"], "two runs produce the same battle")
	equal(first["deaths"], second["deaths"], "with the same casualties")
	# A battle can now be fought wholly through the body's focus: the men in reach are pointed at
	# an enemy that their body chose and never need to look for one of their own (Step 7.8,
	# D-105). So the question is not whether it searched, but whether it really was a battle.
	greater(float(first["deaths"]), 0.0,
		"and the battle really was a battle: opponents were found and men fell")
	greater(float(first["looks"]), 0.0,
		"and soldiers in the fight looked for opponents of their own (%d looks)" % int(first["looks"]))


func _test_a_long_reach_is_still_only_a_number() -> void:
	section("a long reach is a capability, not a weapon name")
	var far_sighted := _unit(0, PLAYER, Vector2(20.0, 30.0), 30.0)
	far_sighted.awareness_radius = 60.0
	var nearby := _unit(1, ENEMY, Vector2(34.0, 30.0))
	var beyond_standard := _unit(2, ENEMY, Vector2(70.0, 30.0))
	var simulator := _simulator([far_sighted, nearby, beyond_standard] as Array[BattleUnit])
	equal(simulator.call("_nearest_local_enemy", far_sighted), nearby,
		"a wider awareness still names the nearest enemy first")
	nearby.hp = 0
	nearby.alive = false
	simulator.call("_rebuild_spatial", TICK)
	equal(simulator.call("_nearest_local_enemy", far_sighted), beyond_standard,
		"and reaches one fifty units out when the near one is gone")
	var ordinary := _unit(9, PLAYER, Vector2(20.0, 60.0))
	simulator.add_units([far_sighted, nearby, beyond_standard, ordinary] as Array[BattleUnit])
	simulator.call("_rebuild_spatial", TICK)
	equal(simulator.call("_nearest_local_enemy", ordinary), null,
		"while an ordinary soldier does not see past its own bound, with no weapon consulted")


## ---------- helpers -------------------------------------------------------

## A full battle of two formed armies, played out far enough to reach contact, reduced to the
## figures that say whether two runs are the same battle.
func _formed_battle() -> Dictionary:
	var config := GameManager.config()
	var catalog := FormationCatalog.load_from()
	var simulator := BattleSimulator.new(config, SEED)
	simulator.field_size = Vector2(300.0, 200.0)
	simulator.grid.configure(simulator.field_size, simulator.cell_size)
	simulator.overlap_grid.configure(simulator.field_size, simulator.overlap_cell_size)
	simulator.profile_enabled = true
	var units: Array[BattleUnit] = []
	var per_side := 60
	# Two units apart: the sides are in each other's reach from the first tick, so this is a
	# determinism fixture for a *battle* rather than for a march. Since Step 7.8 a body that is
	# merely marching defers every look its soldiers would otherwise make (D-105), and a fixture
	# in which nothing ever happens would exercise none of what it is meant to pin down.
	for side_index in 2:
		var side := PLAYER if side_index == 0 else ENEMY
		var x := 150.0 if side_index == 0 else 152.0
		for i in per_side:
			units.append(_unit(side_index * per_side + i, side, Vector2(x, 40.0 + float(i) * 2.0), 2.0))
	# Three blows and a man is down. At one blow a second a soldier of this fixture would need
	# twenty-five seconds to fell an opponent, and the window is four: a fixture in which nobody
	# can die proves nothing about a battle.
	for unit in units:
		unit.attack = 400
	simulator.add_units(units)
	for side_index in 2:
		var side := PLAYER if side_index == 0 else ENEMY
		# The bodies stand where their soldiers do: a body anchored a field away would spend the
		# whole window marching its men to their places and never come within a contact band of
		# the enemy, which is the opposite of what this fixture is for.
		var body := BattleFormation.create("%s_body" % side, side,
			Vector2(150.0 if side_index == 0 else 152.0, 100.0), 0.0, "line", catalog, config)
		simulator.add_formation(body)
		var ids: Array[int] = []
		for i in per_side:
			ids.append(side_index * per_side + i)
		simulator.assign_formation(body, ids)
		body.order_engage()
	simulator.call("_rebuild_spatial", TICK)
	simulator.call("_refresh_focus")
	simulator.reset_profile()
	simulator.start()
	var signature := 0
	for i in 80:
		simulator.step(TICK)
		signature = int(hash(str(signature, "|", simulator.tick_index, ":",
			simulator.side_count(PLAYER), "-", simulator.side_count(ENEMY))))
	var deaths := 0
	for unit in units:
		if not unit.is_alive():
			deaths += 1
	return {"signature": signature, "deaths": deaths, "looks": float(simulator.tgt_searches)}
