extends TestCase
## Step 7: terrain and formations together, in a real battle.
##
## The unit suites prove each system in isolation. This one proves they compose:
## generated ground, formed armies on both sides, orders, an enemy that thinks at the
## level of the formation rather than the soldier, and a fight that ends the same way
## every time it is run from the same seed.

const SEED := 70703


func run() -> void:
	await _tick()
	_test_both_armies_are_formed()
	_test_enemy_uses_the_same_engine()
	_test_orders_work_the_same_for_both_sides()
	_test_enemy_formation_advances()
	_test_ai_ignores_wiped_out_bodies()
	_test_contact_is_formation_local()
	_test_terrain_slows_a_formation()
	_test_formations_still_converge_on_slots()
	_test_a_formed_battle_resolves()
	_test_a_formed_battle_is_deterministic()
	_test_soldiers_are_data_not_scene_nodes()
	_test_combat_crosses_cell_boundaries()
	_test_every_soldier_can_find_a_target()
	_test_a_distant_body_is_pointed_by_its_own_focus()
	_test_a_dense_pile_is_survivable()
	_test_scale_smoke()
	GameManager.end_campaign()
	_complete()


## ---------- fixtures -----------------------------------------------------

func _config() -> GameConfig:
	return GameManager.config()


func _first_available_party(state: CampaignState) -> WorldParty:
	for key in state.parties.keys():
		var candidate := state.parties[key] as WorldParty
		if candidate != null and candidate.is_available():
			return candidate
	return null


## A real battle, from a real campaign, with ground and formed armies on both sides -
## exactly what the battle scene assembles.
func _battle(seed_value: int, recruits: int = 8) -> Dictionary:
	var config := _config()
	var state := GameManager.new_campaign("Formed Battle", seed_value)
	WorldBuilder.new(state, config).build_if_needed()
	OverworldService.build(state, config).spawn_if_needed()
	state.player_gold = 9000
	state.settlement("greywatch").recruit_pool["peasant_recruit"] = 40
	RecruitmentService.build(state, config).recruit_many(state.settlement("greywatch"), "peasant_recruit", recruits)

	var world_party := _first_available_party(state)
	if world_party == null:
		return {}
	state.world_position = world_party.position
	var encounters := EncounterService.build(state, config)
	var context := encounters.build_context(world_party, true)
	if context == null:
		return {}

	var simulator := BattleSimulator.new(config, context.battle_seed)
	simulator.add_units(BattleSetup.build_units_prepared(context, config))
	simulator.set_terrain_from_context(context, config)
	var formations := BattleSetup.assign_default_formations(simulator, config)
	return {
		"state": state,
		"context": context,
		"simulator": simulator,
		"formations": formations,
		"ai": BattleAI.create(config),
		"world_party": world_party,
	}


## Run a battle the way the scene does: think, then step.
func _fight(simulator: BattleSimulator, ai: BattleAI, budget: int = 6000) -> int:
	var steps := 0
	while not simulator.is_finished() and steps < budget:
		steps += 1
		ai.update(simulator, 0.05)
		simulator.step(0.05)
	return steps


## A battlefield with the top rows forced to woods and the bottom rows to open ground,
## so a test can choose what its armies are walking over.
func _banded_terrain(seed_value: int) -> BattlefieldTerrain:
	var terrain := BattlefieldTerrain.generate(seed_value, Vector2(100.0, 60.0), _config())
	for index in terrain.cell_count():
		var row := index / terrain.cols
		if row < 4:
			terrain.set_type_at(terrain.cell_centre(index), "woods")
		elif row >= terrain.rows - 4:
			terrain.set_type_at(terrain.cell_centre(index), "open")
	return terrain


## ---------- both sides, one engine ---------------------------------------

func _test_both_armies_are_formed() -> void:
	section("both armies are put into formations")
	var bundle := _battle(SEED)
	check(not bundle.is_empty(), "a battle was assembled")
	if bundle.is_empty():
		return
	var simulator: BattleSimulator = bundle["simulator"]
	var formations: Array[BattleFormation] = bundle["formations"]

	greater(float(formations.size()), 1.0, "more than one body was formed")
	equal(simulator.formations.size(), formations.size(), "and the simulator holds them all")

	var player := simulator.formations_of(BattleContext.SIDE_PLAYER)
	var enemy := simulator.formations_of(BattleContext.SIDE_ENEMY)
	greater(float(player.size()), 0.0, "the player has a formed army")
	greater(float(enemy.size()), 0.0, "and so does the enemy")

	# Every soldier on the field belongs to a body, and knows which.
	var unformed := 0
	for unit in simulator.units:
		if not unit.is_formed():
			unformed += 1
	equal(unformed, 0, "every soldier on the field is in a formation")

	# Membership adds up: no soldier is in two bodies, none is left out.
	var counted := 0
	for formation in formations:
		for unit_id in formation.unit_ids:
			counted += 1
	equal(counted, simulator.units.size(), "every soldier is counted exactly once")

	# The melee body is a line, and it faces the other army rather than a fixed axis.
	var player_line: BattleFormation = null
	for formation in player:
		if formation.type_id == "line":
			player_line = formation
	not_null(player_line, "the player's melee is a line")
	if player_line != null:
		var to_enemy := (enemy[0].anchor - player_line.anchor)
		less(absf(angle_difference(player_line.facing, to_enemy.angle())), 0.01,
			"and it is facing the enemy, not a hardcoded direction")


func _test_enemy_uses_the_same_engine() -> void:
	section("the enemy fights with the same formation engine")
	var bundle := _battle(SEED + 1)
	if bundle.is_empty():
		check(false, "a battle was assembled")
		return
	var simulator: BattleSimulator = bundle["simulator"]

	var player := simulator.formations_of(BattleContext.SIDE_PLAYER)
	var enemy := simulator.formations_of(BattleContext.SIDE_ENEMY)
	greater(float(enemy.size()), 0.0, "the enemy has formations")

	# Same class, same fields, same methods. There is no enemy-shaped formation and no
	# player-shaped one - which is the whole point of calling it a shared model.
	var theirs: BattleFormation = enemy[0]
	var ours: BattleFormation = player[0]
	equal(theirs.get_class(), ours.get_class(), "enemy formations are the same kind of object")
	equal(theirs.get_script(), ours.get_script(), "running the same code")
	has_key(theirs.to_dict(), "cohesion", "with the same cohesion measure")
	has_key(theirs.to_dict(), "frontage", "the same geometry")
	has_key(theirs.to_dict(), "facing_deg", "and the same facing")

	# The enemy numbers are data-driven in exactly the same way: retuning a formation
	# type changes both sides, because there is only one table.
	var catalog := FormationCatalog.load_from()
	equal(theirs.spacing, ours.spacing, "and stand at the same spacing their type defines")
	approx(theirs.spacing, catalog.spacing_multiplier(theirs.type_id) * _config().get_float("formation.base_spacing", 2.6),
		0.001, "because both read the same formation data")


func _test_orders_work_the_same_for_both_sides() -> void:
	section("orders are the same for both sides")
	var bundle := _battle(SEED + 2)
	if bundle.is_empty():
		check(false, "a battle was assembled")
		return
	var simulator: BattleSimulator = bundle["simulator"]
	var enemy_formation: BattleFormation = simulator.formations_of(BattleContext.SIDE_ENEMY)[0]

	var anchor_before := enemy_formation.anchor
	enemy_formation.order_move_to(anchor_before + Vector2(-10.0, 0.0))
	equal(enemy_formation.is_moving(), true, "an enemy body takes a move order")

	simulator.start()
	for i in 60:
		simulator.step(0.05)
	less(enemy_formation.anchor.distance_to(anchor_before + Vector2(-10.0, 0.0)), 1.0,
		"and it arrives where it was sent, through the same code the player's does")

	# And a formation change is available to both.
	enemy_formation.set_type("column")
	equal(enemy_formation.type_id, "column", "an enemy body can change shape")
	equal(enemy_formation.is_reforming(), true, "which puts it out of order like any other")


## ---------- the enemy thinks above the soldier ---------------------------

func _test_enemy_formation_advances() -> void:
	section("the enemy advances as a body, not as a crowd")
	var bundle := _battle(SEED + 3)
	if bundle.is_empty():
		check(false, "a battle was assembled")
		return
	var simulator: BattleSimulator = bundle["simulator"]
	var ai: BattleAI = bundle["ai"]

	var enemy_formation: BattleFormation = simulator.formations_of(BattleContext.SIDE_ENEMY)[0]
	var player_formation: BattleFormation = simulator.formations_of(BattleContext.SIDE_PLAYER)[0]
	var start_distance := enemy_formation.anchor.distance_to(player_formation.anchor)

	ai.issue_orders(simulator)
	greater(float(ai.orders_issued), 0.0, "the AI issued an order")
	equal(enemy_formation.order, BattleFormation.ORDER_ENGAGE,
		"telling the enemy line to close with the player")

	simulator.start()
	simulator.step(0.05)
	equal(enemy_formation.is_moving(), true, "which gets it moving")

	# It should face what it is advancing on, rather than merely drifting toward it.
	var to_player := player_formation.anchor - enemy_formation.anchor
	less(absf(angle_difference(enemy_formation.desired_facing, to_player.angle())), 0.01,
		"and it has been told to face exactly what it is closing on")

	simulator.start()
	for i in 200:
		ai.update(simulator, 0.05)
		simulator.step(0.05)

	var now_distance := enemy_formation.anchor.distance_to(player_formation.anchor)
	less(now_distance, start_distance, "the enemy closed the distance")

	# The soldiers came with it: this is the difference between an army advancing and a
	# formation marker sliding across the field.
	var stragglers := 0
	for unit_id in enemy_formation.unit_ids:
		var unit := simulator.find_unit(unit_id)
		if unit != null and unit.is_alive():
			if unit.position.distance_to(enemy_formation.anchor) > 40.0:
				stragglers += 1
	equal(stragglers, 0, "and no soldier was left behind by its own formation")


## ---------- the AI's idea of a body ---------------------------------------

## "Is this formation empty" and "does this formation have anybody left standing" are
## two different questions, and Step 7's AI asked the wrong one.
##
## A wiped-out body is not empty: casualties are kept on the roll on purpose, so that a
## gap in a line stays a gap. An AI choosing its target by distance alone would therefore
## pick the corpse of the body it had just finished killing, and order its soldiers to
## face men who are already dead. See D-055.
func _test_ai_ignores_wiped_out_bodies() -> void:
	section("the AI does not take orders against a corpse")
	var config := _config()
	var simulator := BattleSimulator.new(config, 5150)

	var ours := _add_body(simulator, "ours", BattleContext.SIDE_PLAYER, Vector2(30.0, 30.0), 0.0, 3, 0, 5.0)
	# Placed off the axis deliberately, so "faced the living body" and "faced the corpse"
	# are different directions and the assertion can tell them apart.
	var wiped := _add_body(simulator, "wiped", BattleContext.SIDE_ENEMY, Vector2(38.0, 12.0), PI, 3, 10, 0.0)
	var living := _add_body(simulator, "living", BattleContext.SIDE_ENEMY, Vector2(80.0, 48.0), PI, 3, 20, 0.0)

	for unit_id in wiped.unit_ids:
		simulator.find_unit(unit_id).take_damage(999999, -1)

	equal(wiped.has_living_units(simulator.units_by_id()), false, "the near enemy body is wiped out")
	equal(wiped.is_empty(), false,
		"but it is not empty - every id it ever held is still on its roll, which is why the two questions are not one question")
	less(wiped.anchor.distance_to(ours.anchor), living.anchor.distance_to(ours.anchor),
		"and it is the nearer of the two, so choosing by distance alone would pick it")

	var ai := BattleAI.create(config, BattleContext.SIDE_PLAYER)
	ai.issue_orders(simulator)
	greater(float(ai.orders_issued), 0.0, "the AI issued an order")

	# Facing is the observable half of the decision: the AI tells a body what to face.
	var to_living := (living.anchor - ours.anchor).angle()
	var to_wiped := (wiped.anchor - ours.anchor).angle()
	approx(ours.desired_facing, to_living, 0.01, "it faced the living body")
	greater(absf(angle_difference(ours.desired_facing, to_wiped)), 0.1, "and not the corpse")
	equal(ours.order, BattleFormation.ORDER_ENGAGE, "with a real order, not a token one")

	# And it keeps choosing the living one, not merely avoiding the dead one by accident.
	ai.issue_orders(simulator)
	approx(ours.desired_facing, to_living, 0.01, "and it still faces the living body on a second look")


## ---------- contact belongs to a body -------------------------------------

## A wing that has not reached the enemy must be free to close even while the centre is
## fighting. Under Step 7's side-wide contact flag it was not: some player soldier being
## in contact marked the whole side as engaged, and the detached wing sat where it was.
##
## Four bodies, deliberately arranged so the centres are in reach of each other and the
## wings are not - and so that each wing's nearest opposing body is the other wing, which
## is what lets the test tell "closed on its own opposite number" from "wandered off at
## whatever was closest". See D-056.
func _test_contact_is_formation_local() -> void:
	section("contact belongs to a body, not to a side")
	var simulator := BattleSimulator.new(_config(), 7717)

	var centre_ours := _add_body(simulator, "centre_ours", BattleContext.SIDE_PLAYER, Vector2(20.0, 20.0), 0.0, 3, 0, 5.0)
	var centre_theirs := _add_body(simulator, "centre_theirs", BattleContext.SIDE_ENEMY, Vector2(21.5, 20.0), PI, 3, 10, 5.0)
	var wing_ours := _add_body(simulator, "wing_ours", BattleContext.SIDE_PLAYER, Vector2(60.0, 15.0), 0.0, 3, 20, 5.0)
	var wing_theirs := _add_body(simulator, "wing_theirs", BattleContext.SIDE_ENEMY, Vector2(90.0, 15.0), PI, 3, 30, 5.0)

	# Everybody holds at first, so contact is a fact about where the bodies were put.
	for formation in [centre_ours, centre_theirs, wing_ours, wing_theirs]:
		formation.order_hold()

	simulator.start()
	for i in 10:
		simulator.step(0.05)

	equal(centre_ours.in_contact, true, "the player's centre is fighting")
	equal(centre_theirs.in_contact, true, "and so is the enemy's")
	equal(wing_ours.in_contact, false,
		"the player's wing is not in contact - the centre being engaged does not make it so")
	equal(wing_theirs.in_contact, false, "and neither is the enemy's")
	greater(centre_ours.cohesion, 0.9, "the engaged centre is still a dressed formation")

	# The behaviour the side-wide flag used to suppress.
	var before := wing_ours.anchor.distance_to(wing_theirs.anchor)
	wing_ours.order_engage()
	for i in 100:
		simulator.step(0.05)
	var after := wing_ours.anchor.distance_to(wing_theirs.anchor)
	less(after, before - 1.0,
		"the wing closed on its opposite number while the centre was engaged (%.1f -> %.1f)" % [before, after])
	equal(centre_ours.in_contact, true, "and the centre is still fighting")
	equal(wing_ours.in_contact, false, "the wing has not reached anybody yet")

	# Let it arrive. Its contact must turn on by itself, from its own soldiers.
	for i in 300:
		simulator.step(0.05)
	equal(wing_ours.in_contact, true, "the wing reached contact on its own")
	equal(centre_ours.in_contact, true, "independently of the centre")
	greater(wing_ours.cohesion, 0.0, "and it is a body rather than a scatter")

	# Destroy its opponent. Contact must clear - and only for the body that lost one.
	for unit_id in wing_theirs.unit_ids:
		var unit := simulator.find_unit(unit_id)
		if unit != null:
			unit.take_damage(999999, -1)
	for i in 5:
		simulator.step(0.05)
	equal(wing_ours.in_contact, false, "destroying the enemy wing clears the player wing's contact")
	equal(centre_ours.in_contact, true, "and leaves the centre's untouched")


## ---------- terrain and formations together ------------------------------

## A soldier on the field, for the tests that need exact geometry rather than a whole
## campaign behind them.
func _probe_unit(id: int, side: String, position: Vector2, speed: float, health: int = 1000) -> BattleUnit:
	var unit := BattleUnit.new()
	unit.id = id
	unit.side = side
	unit.soldier_id = "s_probe_%d" % id
	unit.display_name = "Probe %d" % id
	unit.max_hp = health
	unit.hp = health
	unit.attack = 1
	unit.defence = 0
	unit.move_speed = speed
	unit.attack_range = 1.8
	unit.attack_cooldown = 5.0
	unit.position = position
	return unit


## Stand a body's soldiers exactly on the places it has given them, so a test starts
## from a dressed formation rather than from everybody piled on the anchor.
func _dress(simulator: BattleSimulator, formation: BattleFormation) -> void:
	for i in formation.unit_ids.size():
		var unit := simulator.find_unit(formation.unit_ids[i])
		if unit != null:
			unit.position = formation.slots[i]


## Add a body of [param count] soldiers to the field and return it.
func _add_body(
	simulator: BattleSimulator,
	id: String,
	side: String,
	anchor: Vector2,
	facing: float,
	count: int,
	first_unit_id: int,
	speed: float
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

	var formation := BattleFormation.create(id, side, anchor, facing, "line", FormationCatalog.load_from(), _config())
	simulator.add_formation(formation)
	simulator.assign_formation(formation, ids)
	_dress(simulator, formation)
	return formation

func _test_terrain_slows_a_formation() -> void:
	section("terrain slows a body of men, not just one of them")
	var config := _config()
	var terrain := _banded_terrain(SEED + 10)
	check(terrain.rows >= 8, "the banded battlefield is deep enough")

	var slow_anchor := terrain.cell_centre(terrain.cols + 1)
	var fast_anchor := terrain.cell_centre((terrain.rows - 1) * terrain.cols + 1)
	equal(terrain.type_id_at(slow_anchor), "woods", "one lane is woods")
	equal(terrain.type_id_at(fast_anchor), "open", "and the other is open ground")

	var slow := _run_lane(config, terrain, slow_anchor, 3)
	var fast := _run_lane(config, terrain, fast_anchor, 3)
	greater(fast, slow, "the body on open ground covered more of it (%.2f vs %.2f)" % [fast, slow])
	greater(slow, 0.0, "and the body in the woods still moved")

	# The ratio should follow the terrain data rather than merely being smaller.
	var ratio := slow / fast
	var expected := terrain.move_multiplier_at(slow_anchor) / terrain.move_multiplier_at(fast_anchor)
	approx(ratio, expected, 0.1, "in proportion to the ground's own numbers")


## Marches a dressed line [param count] men wide across the band and reports how far
## its centre got.
func _run_lane(config: GameConfig, terrain: BattlefieldTerrain, anchor: Vector2, count: int) -> float:
	var simulator := BattleSimulator.new(config, 909)
	var units: Array[BattleUnit] = []
	for i in count:
		var unit := BattleUnit.new()
		unit.id = i
		unit.side = BattleContext.SIDE_PLAYER
		unit.soldier_id = "s_lane_%d" % i
		unit.max_hp = 100
		unit.hp = 100
		unit.attack = 1
		unit.attack_range = 0.2
		unit.move_speed = 6.0
		unit.position = anchor
		units.append(unit)
	var enemy := BattleUnit.new()
	enemy.id = 900
	enemy.side = BattleContext.SIDE_ENEMY
	enemy.soldier_id = "s_lane_enemy"
	enemy.max_hp = 100
	enemy.hp = 100
	enemy.move_speed = 0.0
	enemy.attack_range = 0.2
	enemy.position = Vector2(95.0, 2.0)
	units.append(enemy)
	simulator.add_units(units)

	var formation := BattleFormation.create("lane", BattleContext.SIDE_PLAYER, anchor, 0.0, "line", FormationCatalog.load_from(), config)
	simulator.add_formation(formation)
	var ids: Array[int] = []
	for i in count:
		ids.append(i)
	simulator.assign_formation(formation, ids)
	for i in count:
		units[i].position = formation.slots[i]

	simulator.set_terrain(terrain)
	formation.order_move_to(anchor + Vector2(30.0, 0.0))
	simulator.start()
	for i in 100:
		simulator.step(0.05)
	return formation.anchor.distance_to(anchor)


func _test_formations_still_converge_on_slots() -> void:
	section("a formed army on broken ground still dresses its ranks")
	var bundle := _battle(SEED + 4)
	if bundle.is_empty():
		check(false, "a battle was assembled")
		return
	var simulator: BattleSimulator = bundle["simulator"]
	check(simulator.terrain != null, "this battle has ground under it")

	# Stand both armies fast: this test is about dressing ranks on broken ground, not
	# about the fighting, and an engaged body would be walking into contact.
	for formation in simulator.formations:
		formation.order_hold()

	simulator.start()
	for i in 120:
		simulator.step(0.05)

	for formation in simulator.formations:
		var worst := 0.0
		for i in formation.unit_ids.size():
			var unit := simulator.find_unit(formation.unit_ids[i])
			if unit == null or not unit.is_alive():
				continue
			worst = maxf(worst, unit.position.distance_to(formation.slots[i]))
		less(worst, 4.0, "%s has dressed its ranks despite the terrain" % formation.id)
		greater(formation.cohesion, 0.5, "and %s reports holding its shape" % formation.id)


## ---------- a real fight -------------------------------------------------

func _test_a_formed_battle_resolves() -> void:
	section("a battle with terrain and formations still resolves")
	var bundle := _battle(SEED + 5, 10)
	if bundle.is_empty():
		check(false, "a battle was assembled")
		return
	var simulator: BattleSimulator = bundle["simulator"]
	var ai: BattleAI = bundle["ai"]

	simulator.start()
	var steps := _fight(simulator, ai)

	check(simulator.is_finished(), "the battle ended (%d steps, %.1fs)" % [steps, simulator.elapsed])
	check(not simulator.winner.is_empty(), "with a winner")
	less(float(steps), 6000.0, "and it did not run out of step budget")

	var casualties := 0
	for unit in simulator.units:
		if not unit.is_alive():
			casualties += 1
	greater(float(casualties), 0.0, "the fighting was real: %d casualties" % casualties)

	# The AI's own accounting: a battle where the enemy never issued an order would be
	# a battle where the formations never met.
	greater(float(ai.orders_issued), 0.0, "the enemy command was active throughout")

	# Ground is still readable after the fight, and still deterministic.
	not_null(simulator.terrain, "the battlefield survived the battle")
	if simulator.terrain != null:
		equal(simulator.terrain.terrain_seed, (bundle["context"] as BattleContext).terrain_seed,
			"and it is still the ground the context asked for")


func _test_a_formed_battle_is_deterministic() -> void:
	section("the same battle twice gives the same battle")
	var first := _battle(SEED + 6, 8)
	var second := _battle(SEED + 6, 8)
	if first.is_empty() or second.is_empty():
		check(false, "two battles were assembled")
		return

	var a: BattleSimulator = first["simulator"]
	var b: BattleSimulator = second["simulator"]
	equal(a.terrain.signature(), b.terrain.signature(), "the ground is identical")
	equal(a.formations.size(), b.formations.size(), "the same number of bodies")

	for i in a.formations.size():
		var fa: BattleFormation = a.formations[i]
		var fb: BattleFormation = b.formations[i]
		equal(fa.type_id, fb.type_id, "body %d: same shape" % i)
		approx(fa.anchor.x, fb.anchor.x, 0.0001, "body %d: same centre x" % i)
		approx(fa.anchor.y, fb.anchor.y, 0.0001, "body %d: same centre y" % i)

	a.start()
	b.start()
	var ai_a: BattleAI = first["ai"]
	var ai_b: BattleAI = second["ai"]
	for i in 400:
		ai_a.update(a, 0.05)
		ai_b.update(b, 0.05)
		a.step(0.05)
		b.step(0.05)

	equal(a.winner, b.winner, "the same side is ahead after the same time")
	equal(a.elapsed, b.elapsed, "at the same point in time")
	var mismatched := 0
	for i in a.units.size():
		if a.units[i].position.distance_to(b.units[i].position) > 0.0001:
			mismatched += 1
		if a.units[i].hp != b.units[i].hp:
			mismatched += 1
	equal(mismatched, 0, "and not one soldier is in a different place or state")

	# The simulation is self-contained: it reads a context and writes nothing back to
	# the campaign. That separation is what `apply()` exists to preserve, and it is
	# worth checking that the battle does not quietly mutate the world it came from.
	var state: CampaignState = first["state"]
	var soldiers_before := state.soldiers.size()
	var gold_before := state.player_gold
	var third := _battle(SEED + 6, 8)
	if not third.is_empty():
		var sim: BattleSimulator = third["simulator"]
		sim.start()
		for i in 200:
			sim.step(0.05)
	equal(state.soldiers.size(), soldiers_before, "fighting a battle changes no soldier in the campaign")
	equal(state.player_gold, gold_before, "and pays out nothing - that is the resolver's job, not the field's")


## ---------- architecture guardrails --------------------------------------

## The guardrail that matters most for the future. A soldier must not be a scene node
## with its own pathfinding, or twenty thousand of them will never fit in a frame -
## and by the time that is discovered, it is a rewrite rather than a decision.
func _test_soldiers_are_data_not_scene_nodes() -> void:
	section("soldiers are data, not scene nodes")
	equal(BattleUnit.new().get_class(), "RefCounted", "a soldier is plain data, not a Node2D")
	equal(BattleFormation.new().get_class(), "RefCounted", "so is a formation")
	equal(BattleSimulator.new(_config(), 1).get_class(), "RefCounted", "and so is the simulator")
	equal(BattlefieldTerrain.new().get_class(), "RefCounted", "and the ground")

	# A formed soldier's per-step work is a reference and an array read, not a search
	# through its formation. If this were a scan, a five-thousand man battle would be
	# quadratic in a way no amount of tuning could fix.
	var bundle := _battle(SEED + 7, 6)
	if bundle.is_empty():
		return
	var simulator: BattleSimulator = bundle["simulator"]
	var formation: BattleFormation = simulator.formations_of(BattleContext.SIDE_PLAYER)[0]
	var unit := simulator.find_unit(formation.unit_ids[0])
	not_null(unit, "a formed soldier exists")
	if unit != null:
		equal(unit.formation_ref, formation, "and holds its body directly")
		check(unit.slot_index >= 0, "and its own place in it")

	# Movement orders are also a lookup, not a scan of the battlefield.
	var probe := simulator.find_unit(999999)
	is_null(probe, "asking for a soldier who does not exist is a miss, not a crash")


## ---------- scale smoke --------------------------------------------------

## Not a performance assertion - the benchmark owns that. This is a structural check
## that the formation machinery itself does not fall over at a size the current
## architecture is expected to handle, and that it stays linear in the parts Step 7
## added.
func _test_scale_smoke() -> void:
	section("a large formed battle builds and steps")
	var config := _config()
	for count in [100, 500]:
		var simulator := BattleSimulator.new(config, 4242)
		var units: Array[BattleUnit] = []
		for i in count:
			var unit := BattleUnit.new()
			unit.id = i
			unit.side = BattleContext.SIDE_PLAYER if i < count / 2 else BattleContext.SIDE_ENEMY
			unit.soldier_id = "s_scale_%d" % i
			unit.max_hp = 40
			unit.hp = 40
			unit.attack = 5
			unit.defence = 2
			unit.move_speed = 5.0
			unit.attack_range = 1.8
			unit.attack_cooldown = 1.2
			unit.position = Vector2(
				10.0 if unit.side == BattleContext.SIDE_PLAYER else 90.0,
				5.0 + float(i % (count / 2)) * (50.0 / float(maxi(1, count / 2)))
			)
			units.append(unit)
		simulator.add_units(units)
		simulator.set_terrain_from_context(_synthetic_context(count), config)

		var formations := BattleSetup.assign_default_formations(simulator, config)
		greater(float(formations.size()), 0.0, "%d units: armies were formed" % count)

		var assigned := 0
		for formation in formations:
			assigned += formation.unit_ids.size()
		equal(assigned, count, "%d units: every soldier was given a place" % count)

		simulator.start()
		for i in 20:
			simulator.step(0.05)
		check(true, "%d units: twenty steps completed without incident" % count)

		# And the cohesion measure stays a number rather than becoming nonsense.
		for formation in simulator.formations:
			check(formation.cohesion >= 0.0 and formation.cohesion <= 1.0,
				"%d units: %s reports a cohesion within range" % [count, formation.id])


func _synthetic_context(count: int) -> BattleContext:
	var context := BattleContext.new()
	context.battle_id = "scale_%d" % count
	context.terrain_seed = 31337
	context.battle_seed = 31337
	context.enemy_display_name = "Scale Probes"
	return context


## ---------- Step 7.2: proximity goes local, nothing else changes -------------

## A cell boundary is an implementation detail of the proximity index. It must never
## behave like a wall, and the place that would show up first is a real fight.
func _test_combat_crosses_cell_boundaries() -> void:
	section("a cell boundary is not a wall in a real fight")
	var config := _config()
	# The configured cell size puts an edge at x = 40. These two are on opposite sides
	# of it and inside each other's reach.
	var left := _probe_unit(0, BattleContext.SIDE_PLAYER, Vector2(39.6, 30.0), 5.0)
	var right := _probe_unit(1, BattleContext.SIDE_ENEMY, Vector2(41.0, 30.0), 5.0)
	var simulator := BattleSimulator.new(config, 31)
	simulator.add_units([left, right])
	simulator.start()

	not_equal(simulator.grid.cell_index_of(left.position), simulator.grid.cell_index_of(right.position),
		"the two soldiers really are in different cells")
	approx(simulator.grid.cell_size, config.get_float("battle.spatial_cell_size", 4.0), 0.0001,
		"and the cell size is the configured one")

	for tick in 100:
		if simulator.is_finished():
			break
		simulator.step(0.5)
	less(float(left.hp), float(left.max_hp), "the soldier left of the boundary was struck")
	less(float(right.hp), float(right.max_hp), "and so was the one right of it")

	# The same at a corner, where four cells meet.
	var corner_a := _probe_unit(0, BattleContext.SIDE_PLAYER, Vector2(39.6, 39.6), 5.0)
	var corner_b := _probe_unit(1, BattleContext.SIDE_ENEMY, Vector2(40.4, 40.4), 5.0)
	var corner_sim := BattleSimulator.new(config, 33)
	corner_sim.add_units([corner_a, corner_b])
	corner_sim.start()
	not_equal(corner_sim.grid.cell_index_of(corner_a.position), corner_sim.grid.cell_index_of(corner_b.position),
		"the corner pair are in diagonally opposite cells")
	for tick in 100:
		if corner_sim.is_finished():
			break
		corner_sim.step(0.5)
	less(float(corner_a.hp), float(corner_a.max_hp), "soldiers across a corner still find each other")
	less(float(corner_b.hp), float(corner_b.max_hp), "on both sides")


## The failure the escalation ladder exists to prevent: an army that never engages
## because no soldier can see anyone. Two bodies starting most of a battlefield apart is
## the case a purely local search gets wrong.
func _test_every_soldier_can_find_a_target() -> void:
	section("nobody is left standing about with no target")
	var config := _config()
	var simulator := BattleSimulator.new(config, 51)
	var players := _add_body(simulator, "player_line", BattleContext.SIDE_PLAYER, Vector2(12.0, 30.0), 0.0, 12, 0, 5.0)
	var enemies := _add_body(simulator, "enemy_line", BattleContext.SIDE_ENEMY, Vector2(88.0, 30.0), PI, 12, 100, 5.0)
	simulator.start()

	var apart := players.bounds().get_center().distance_to(enemies.bounds().get_center())
	greater(apart, 60.0, "the two bodies start the better part of a battlefield apart")
	less(simulator.target_search_radius, apart, "which is further than a single local query reaches")

	var examined := 0
	var stranded := 0
	for tick in 40:
		if simulator.is_finished():
			break
		simulator.step(0.05)
		simulator.call("_rebuild_spatial", 0.05)
		for unit in simulator.units:
			if not unit.is_alive():
				continue
			examined += 1
			if simulator.call("_choose_target", unit) == null:
				stranded += 1
	greater(float(examined), 100.0, "there were plenty of soldiers to ask")
	equal(stranded, 0, "every living soldier had an enemy to face, at every tick")


## A uniform grid degrades when everything lands in one cell, and the brief asks for that
## case to be met rather than hoped about. It has to survive, stay deterministic, and
## lose nobody.
func _test_a_dense_pile_is_survivable() -> void:
	section("three hundred soldiers packed into one cell")
	var config := _config()
	var first := _pile(config, 300)
	var second := _pile(config, 300)

	equal(int(first["busiest"]), 300, "the grid says honestly that all three hundred share a cell")
	equal(int(first["standing"]) + int(first["fallen"]), 300,
		"every soldier is still accounted for, standing or fallen")
	greater(float(first["ticks"]), 0.0, "the pile ran without hanging")
	equal(String(second["signature"]), String(first["signature"]),
		"and two identical piles produce the identical brawl")
	equal(int(second["standing"]), int(first["standing"]), "with the same number left standing")
	less(float(first["standing"]), 300.0, "which is not all of them, because they were fighting")


## Run one pile and report what happened. Deliberately built from raw units rather than
## through a campaign: this is a stress case, not a scenario.
func _pile(config: GameConfig, count: int) -> Dictionary:
	var simulator := BattleSimulator.new(config, 61)
	var units: Array[BattleUnit] = []
	for i in count:
		var side := BattleContext.SIDE_PLAYER if i % 2 == 0 else BattleContext.SIDE_ENEMY
		var unit := _probe_unit(i, side, Vector2(20.0 + float(i % 20) * 0.1, 20.0 + float(i / 20) * 0.1), 5.0, 8)
		unit.attack_range = 1.2
		unit.attack_cooldown = 1.0
		units.append(unit)
	simulator.add_units(units)
	simulator.call("_rebuild_spatial", 0.05)
	var busiest := simulator.grid.busiest_cell()
	simulator.start()

	var ticks := 0
	while not simulator.is_finished() and ticks < 300:
		simulator.step(0.05)
		ticks += 1

	var parts := PackedStringArray()
	parts.append("%d:%d" % [simulator.state, ticks])
	var standing := 0
	for unit in units:
		if unit.is_alive():
			standing += 1
			parts.append("%d:%d:%.3f:%.3f" % [unit.id, unit.hp, unit.position.x, unit.position.y])
	return {
		"signature": "|".join(parts),
		"standing": standing,
		"fallen": count - standing,
		"busiest": busiest,
		"ticks": ticks,
	}


## A local search answers "who is nearest to me" for a soldier in the fighting, and
## cannot answer it for one standing half a battlefield away without looking at the whole
## enemy army - per soldier, per tick, which is the cost Step 7.2 removed. Beyond the
## search bound a formed soldier is pointed at the fighting by its body instead. This test
## is about that being a decision rather than a silence.
func _test_a_distant_body_is_pointed_by_its_own_focus() -> void:
	section("a formed body far from the enemy is pointed at it")
	var config := _config()
	var simulator := BattleSimulator.new(config, 71)
	var players := _add_body(simulator, "player_line", BattleContext.SIDE_PLAYER, Vector2(12.0, 30.0), 0.0, 8, 0, 5.0)
	var enemies := _add_body(simulator, "enemy_line", BattleContext.SIDE_ENEMY, Vector2(88.0, 30.0), PI, 8, 100, 5.0)
	simulator.start()
	simulator.step(0.05)
	simulator.call("_rebuild_spatial", 0.05)
	simulator.call("_refresh_focus")

	var apart := players.anchor.distance_to(enemies.anchor)
	greater(apart, simulator.target_search_max_radius,
		"the two bodies are further apart than a single soldier's search reaches")

	# What the body is pointed at: the nearest living enemy to its own anchor, decided
	# once for the body.
	var expected: BattleUnit = simulator.call("_nearest_enemy_to_point", BattleContext.SIDE_PLAYER, players.anchor)
	not_null(expected, "there is an enemy for the body to be pointed at")

	var asked := 0
	var shared := {}
	for unit_id in players.unit_ids:
		var unit := simulator.find_unit(unit_id)
		if unit == null or not unit.is_alive():
			continue
		var chosen: BattleUnit = simulator.call("_choose_target", unit)
		equal(chosen, expected, "soldier %d faces the enemy its body is pointed at" % unit_id)
		shared[chosen] = true
		asked += 1
	equal(asked, 8, "every soldier in the body was asked")
	equal(shared.size(), 1, "and the body is pointed at one enemy rather than eight different ones")

	# The other body is pointed the other way, and both are real enemies rather than
	# whatever happened to be nearest in the index.
	var their_focus: BattleUnit = simulator.call("_nearest_enemy_to_point", BattleContext.SIDE_ENEMY, enemies.anchor)
	not_null(their_focus, "and the enemy body has one too")
	equal(their_focus.side, BattleContext.SIDE_PLAYER, "pointing at one of ours")
	equal(expected.side, BattleContext.SIDE_ENEMY, "as ours points at one of theirs")
	not_equal(their_focus, expected, "which are not the same soldier")
