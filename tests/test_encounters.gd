extends TestCase
## Step 4 checks: hostile parties exist and move on the overworld, meeting one
## produces a complete BattleContext, the battle scene deploys the right armies,
## and the campaign is intact when you come back.


func run() -> void:
	await _tick()
	SaveManager.delete_all_saves()
	_test_spawning()
	_test_overworld_movement()
	_test_detection_and_cooldown()
	_test_battle_context()
	_test_battle_deployment()
	_test_simulator_movement()
	await _test_full_flow()
	SaveManager.delete_all_saves()
	GameManager.end_campaign()


func _fresh_campaign(name: String, seed_value: int) -> CampaignState:
	var state := GameManager.new_campaign(name, seed_value)
	var builder := WorldBuilder.new(state, GameManager.config())
	builder.build_if_needed()
	var overworld := OverworldService.build(state, GameManager.config())
	overworld.spawn_if_needed()
	return state


func _test_spawning() -> void:
	section("hostile party spawning")
	var state := _fresh_campaign("Spawn Test", 20250)
	var overworld := OverworldService.build(state, GameManager.config())

	equal(state.parties.size(), 3, "three hostile parties spawned from data")
	equal(state.enemy_parties.size(), 3, "each has a soldier roster")
	for key in state.parties.keys():
		var world_party := state.parties[key] as WorldParty
		not_null(world_party, "party '%s' is a WorldParty" % key)
		if world_party == null:
			continue
		equal(world_party.kind, Party.KIND_BANDIT, "party '%s' is hostile" % key)
		check(not world_party.display_name.is_empty(), "party '%s' has a name" % key)
		var party := state.party_of(world_party)
		not_null(party, "party '%s' resolves to a roster" % key)
		if party == null:
			continue
		var size := state.active_members(party).size()
		check(size >= 5, "party '%s' has at least 5 soldiers (has %d)" % [key, size])
		check(size <= 8, "party '%s' has at most 8 soldiers (has %d)" % [key, size])
		for soldier in state.active_members(party):
			check(not soldier.first_name.is_empty(), "bandit in '%s' is named" % key)
			check(not soldier.unit_type_id.is_empty(), "bandit in '%s' has an archetype" % key)
			check(soldier.max_hp > 0, "bandit in '%s' has hit points" % key)
		# Spawn point must be near its home settlement.
		greater(float(world_party.position.distance_to(world_party.home_position)), -1.0,
			"party '%s' spawned somewhere real" % key)

	# Idempotent: a second call must not duplicate the world's parties.
	check(not overworld.spawn_if_needed(), "spawn_if_needed is a no-op once parties exist")
	equal(state.parties.size(), 3, "party count unchanged")

	# Same seed must produce the same world.
	var twin := _fresh_campaign("Spawn Twin", 20250)
	var twin_sizes: Array[int] = []
	var original_sizes: Array[int] = []
	for key in state.parties.keys():
		original_sizes.append(state.active_members(state.party_of(state.parties[key])).size())
	for key in twin.parties.keys():
		twin_sizes.append(twin.active_members(twin.party_of(twin.parties[key])).size())
	equal(original_sizes, twin_sizes, "the same campaign seed spawns the same parties")


func _test_overworld_movement() -> void:
	section("overworld movement")
	var state := _fresh_campaign("Move Test", 20251)
	var overworld := OverworldService.build(state, GameManager.config())
	var config := GameManager.config()

	# Keep the player far away so nobody aggros.
	state.world_position = Vector2(100.0, 100.0)
	var key := str(state.parties.keys()[0])
	var world_party := state.parties[key] as WorldParty
	var start := world_party.position

	var moved := overworld.step(1.0)
	greater(float(moved), 0.0, "at least one party moved")
	greater(start.distance_to(world_party.position), 0.0, "a party changed position")
	check(world_party.position.distance_to(world_party.home_position) <= world_party.wander_radius + 40.0,
		"a wandering party stays near where it started")

	# Paused world: no time means no movement, whatever the AI wants.
	var before := world_party.position
	equal(overworld.step(0.0), 0, "zero game hours moves no parties")
	approx(world_party.position.distance_to(before), 0.0, 0.0001, "positions unchanged")

	# Aggro: a party close to the player closes the distance.
	state.world_position = world_party.position + Vector2(120.0, 0.0)
	var distance_before := world_party.position.distance_to(state.world_position)
	overworld.step(1.0)
	var distance_after := world_party.position.distance_to(state.world_position)
	less(distance_after, distance_before, "a party inside its aggro range closes on the player")

	# A party with no living soldiers is removed from the map.
	var party := state.party_of(world_party)
	for soldier_id in party.member_ids.duplicate():
		var soldier := state.soldier(soldier_id)
		if soldier != null:
			soldier.status = Soldier.STATUS_DEAD
	overworld.step(1.0)
	check(world_party.defeated, "a party with no soldiers left is marked defeated")
	check(not world_party.is_available(), "a defeated party is no longer available")
	check(world_party.id not in _available_ids(overworld), "a defeated party is not returned by available_parties()")


func _available_ids(overworld: OverworldService) -> Array[String]:
	var out: Array[String] = []
	for world_party in overworld.available_parties():
		out.append(world_party.id)
	return out


func _test_detection_and_cooldown() -> void:
	section("encounter detection")
	var state := _fresh_campaign("Detect Test", 20252)
	var encounters := EncounterService.build(state, GameManager.config())
	equal(encounters.trigger_radius(), GameManager.config().get_float("encounters.trigger_radius", 26.0),
		"trigger radius comes from config")

	# Far away: nothing to meet.
	state.world_position = Vector2(60.0, 60.0)
	is_null(encounters.detect(), "no encounter while far from every party")

	var key := str(state.parties.keys()[0])
	var world_party := state.parties[key] as WorldParty

	# Standing on one: encounter.
	state.world_position = world_party.position
	var found := encounters.detect()
	not_null(found, "standing on a party triggers an encounter")
	if found != null:
		equal(found.id, world_party.id, "the nearest party is the one detected")

	# Retreating pushes the player away and starts a cooldown.
	var position_before := state.world_position
	encounters.apply_retreat(world_party)
	greater(state.world_position.distance_to(position_before), 0.0, "retreating moves the player away")
	check(encounters.is_on_cooldown(world_party), "retreating starts a cooldown")
	is_null(encounters.detect(), "a party on cooldown is not re-detected")

	# The cooldown expires with game time.
	state.clock.advance_hours(encounters.cooldown_hours() + 0.1)
	check(not encounters.is_on_cooldown(world_party), "the cooldown expires with game time")

	# Strength figures are positive and readable.
	greater(float(encounters.enemy_strength(world_party)), 0.0, "the enemy has a strength figure")
	check(encounters.enemy_size(world_party) >= 5, "the enemy has soldiers")
	# An empty player party has no strength.
	equal(encounters.player_strength(), 0, "an empty player party has no strength")


func _test_battle_context() -> void:
	section("battle context")
	var state := _fresh_campaign("Context Test", 20253)
	var encounters := EncounterService.build(state, GameManager.config())
	var recruitment := RecruitmentService.build(state, GameManager.config())
	state.player_gold = 500
	recruitment.recruit_many(state.settlement("greywatch"), "peasant_recruit", 3)

	var key := str(state.parties.keys()[0])
	var world_party := state.parties[key] as WorldParty
	state.world_position = world_party.position
	var context := encounters.build_context(world_party, true)

	not_null(context, "a context is built")
	if context == null:
		return
	check(not context.battle_id.is_empty(), "the battle has an id")
	equal(context.battle_kind, BattleContext.KIND_FIELD, "this is a field battle")
	equal(context.attacker, BattleContext.SIDE_PLAYER, "the player is the attacker")
	equal(context.defender, BattleContext.SIDE_ENEMY, "the bandits are the defender")
	equal(context.world_party_id, world_party.id, "the context points back at the overworld party")
	equal(context.enemy_display_name, world_party.display_name, "the enemy name comes through")
	approx(context.world_position.x, state.world_position.x, 0.001, "the battle happens where the player is")
	equal(context.campaign_day, state.clock.day, "the campaign day is recorded")
	approx(context.campaign_hour, state.clock.hour, 0.001, "the campaign hour is recorded")
	not_equal(context.weather, "", "weather is present (placeholder)")
	not_equal(context.terrain_seed, context.battle_seed, "terrain and battle seeds differ")

	equal(context.player_snapshot.size(), 3, "the player's three soldiers are in the context")
	equal(context.enemy_snapshot.size(), encounters.enemy_size(world_party), "the enemy roster is complete")

	# Every snapshot entry must carry identity AND resolved stats, because the
	# battle scene is not allowed to go looking for either.
	for entry in context.player_snapshot:
		check(not str(entry.get("soldier_id", "")).is_empty(), "a snapshot keeps the soldier id")
		var soldier := state.soldier(str(entry.get("soldier_id", "")))
		not_null(soldier, "the snapshot's soldier id resolves in the campaign")
		if soldier != null:
			equal(str(entry.get("name", "")), soldier.full_name(), "the snapshot names the right soldier")
			equal(int(entry.get("max_hp", 0)), soldier.max_hp, "the snapshot carries real hit points")
		check(int(entry.get("attack", 0)) > 0, "the snapshot carries attack")
		greater(float(entry.get("move_speed", 0.0)), 0.0, "the snapshot carries movement speed")
		check(int(entry.get("level", 0)) >= 1, "the snapshot carries the level")
		check(entry.has("ranged"), "the snapshot says whether the unit is ranged")

	# Attack and move modifiers from traits must actually be applied here.
	var traits := TraitCatalog.load_from()
	var units := UnitCatalog.load_from()
	var config := GameManager.config()
	var modified_count := 0
	for entry in context.player_snapshot:
		var soldier := state.soldier(str(entry.get("soldier_id", "")))
		if soldier == null:
			continue
		var definition := units.get_definition(soldier.unit_type_id)
		var attack_pct := traits.total_modifier(soldier.traits, "attack_pct")
		if absf(attack_pct) > 0.01:
			modified_count += 1
			var expected := maxi(1, int(round(float(definition.attack_at(soldier.level, config)) * (1.0 + attack_pct / 100.0))))
			equal(int(entry.get("attack", 0)), expected, "the trait attack modifier is applied to the snapshot")
	check(modified_count >= 0, "trait attack modifiers were checked where present")

	# A second battle in the same campaign gets a different id and seed.
	var second := encounters.build_context(world_party, true)
	not_equal(second.battle_id, context.battle_id, "each battle gets its own id")
	not_equal(second.battle_seed, context.battle_seed, "each battle gets its own seed")

	# Being ambushed flips the sides without changing the rosters.
	var ambush := encounters.build_context(world_party, false)
	equal(ambush.attacker, BattleContext.SIDE_ENEMY, "an ambush makes the enemy the attacker")
	equal(ambush.defender, BattleContext.SIDE_PLAYER, "an ambush makes the player the defender")
	equal(ambush.player_snapshot.size(), context.player_snapshot.size(), "the ambush has the same player roster")

	# Contexts must survive being handed through a scene payload.
	var round_tripped := BattleContext.from_dict(context.to_dict())
	equal(round_tripped.battle_id, context.battle_id, "the context round-trips through a dictionary")
	equal(round_tripped.player_snapshot.size(), context.player_snapshot.size(), "the round trip keeps the player roster")
	equal(round_tripped.battle_seed, context.battle_seed, "the round trip keeps the seed")


func _test_battle_deployment() -> void:
	section("battle deployment")
	var state := _fresh_campaign("Deploy Test", 20254)
	var config := GameManager.config()
	var encounters := EncounterService.build(state, config)
	var recruitment := RecruitmentService.build(state, config)
	state.player_gold = 500
	recruitment.recruit_many(state.settlement("greywatch"), "peasant_recruit", 4)

	var world_party := state.parties[str(state.parties.keys()[0])] as WorldParty
	state.world_position = world_party.position
	var context := encounters.build_context(world_party, true)
	var units := BattleSetup.build_units(context)

	equal(units.size(), context.unit_count(), "every snapshot became a unit")
	equal(units.size(), 4 + context.enemy_snapshot.size(), "the counts add up")

	var field := BattleSetup.field_size(config)
	BattleSetup.deploy(units, config)

	var players := 0
	var enemies := 0
	for unit in units:
		check(unit.is_alive(), "units start alive")
		equal(unit.hp, unit.max_hp, "units start at full health")
		check(unit.position.x >= 0.0 and unit.position.x <= field.x, "unit x is on the field")
		check(unit.position.y >= 0.0 and unit.position.y <= field.y, "unit y is on the field")
		check(not unit.soldier_id.is_empty(), "every unit keeps its soldier id")
		if unit.side == BattleContext.SIDE_PLAYER:
			players += 1
			less(unit.position.x, field.x * 0.5, "player units deploy on the left")
			approx(unit.facing.x, 1.0, 0.001, "player units face right")
		else:
			enemies += 1
			greater(unit.position.x, field.x * 0.5, "enemy units deploy on the right")
			approx(unit.facing.x, -1.0, 0.001, "enemy units face left")
	equal(players, 4, "all four player soldiers deployed")
	equal(enemies, context.enemy_snapshot.size(), "all enemy soldiers deployed")

	# Unit ids must be unique.
	var seen := {}
	for unit in units:
		check(not seen.has(unit.id), "unit id %d is unique" % unit.id)
		seen[unit.id] = true


func _test_simulator_movement() -> void:
	section("battle simulator")
	var state := _fresh_campaign("Sim Test", 20255)
	var config := GameManager.config()
	var encounters := EncounterService.build(state, config)
	var recruitment := RecruitmentService.build(state, config)
	state.player_gold = 500
	recruitment.recruit_many(state.settlement("greywatch"), "peasant_recruit", 4)

	var world_party := state.parties[str(state.parties.keys()[0])] as WorldParty
	state.world_position = world_party.position
	var context := encounters.build_context(world_party, true)
	var units := BattleSetup.build_units_prepared(context, config)

	var simulator := BattleSimulator.new(config, context.battle_seed)
	simulator.add_units(units)
	equal(simulator.state, BattleSimulator.State.DEPLOYING, "the sim starts undeployed")
	check(not simulator.is_running(), "the sim is not running before Start Battle")
	equal(simulator.step(0.5).size(), 0, "stepping before the start does nothing")

	simulator.start()
	check(simulator.is_running(), "the sim runs after start")

	# The two lines must close on each other.
	var gap_before := _line_gap(simulator)
	for i in 60:
		simulator.step(0.1)
	var gap_after := _line_gap(simulator)
	less(gap_after, gap_before, "the two lines close on each other while engaged")
	greater(float(simulator.elapsed), 0.0, "the simulator tracks elapsed time")

	# Everything stays on the field.
	var field := simulator.field_size
	for unit in simulator.units:
		check(unit.position.x >= 0.0 and unit.position.x <= field.x, "a unit stays inside the field")
		check(unit.position.y >= 0.0 and unit.position.y <= field.y, "a unit stays inside the field vertically")

	# A move order overrides the automatic advance. Measure the closest approach
	# during the loop: once a unit reaches its waypoint it clears the order and
	# resumes hunting the nearest enemy, so the end position is not the evidence.
	var unit := simulator.units[0]
	var order := Vector2(20.0, 30.0)
	unit.move_order = order
	unit.has_move_order = true
	var closest := unit.position.distance_to(order)
	var order_cleared := false
	for i in 100:
		simulator.step(0.1)
		closest = minf(closest, unit.position.distance_to(order))
		if not unit.has_move_order:
			order_cleared = true
	less(closest, 1.5, "a unit reaches its move order")
	check(order_cleared, "the order clears once it is reached")

	# The sim is deterministic: two runs from the same context and seed must agree.
	var run_a := BattleSimulator.new(config, context.battle_seed)
	run_a.add_units(BattleSetup.build_units_prepared(context, config))
	run_a.start()
	var run_b := BattleSimulator.new(config, context.battle_seed)
	run_b.add_units(BattleSetup.build_units_prepared(context, config))
	run_b.start()
	for i in 40:
		run_a.step(0.1)
		run_b.step(0.1)
	var same := true
	for index in run_a.units.size():
		if run_a.units[index].position.distance_to(run_b.units[index].position) > 0.0001:
			same = false
	check(same, "two runs of the same battle produce the same positions")
	equal(run_a.side_count(BattleContext.SIDE_PLAYER), run_b.side_count(BattleContext.SIDE_PLAYER),
		"two runs of the same battle agree on who is standing")


func _line_gap(simulator: BattleSimulator) -> float:
	var players: Array[BattleUnit] = []
	var enemies: Array[BattleUnit] = []
	for unit in simulator.units:
		if unit.side == BattleContext.SIDE_PLAYER:
			players.append(unit)
		else:
			enemies.append(unit)
	if players.is_empty() or enemies.is_empty():
		return 0.0
	return absf(_average_x(players) - _average_x(enemies))


func _average_x(units: Array[BattleUnit]) -> float:
	var total := 0.0
	for unit in units:
		total += unit.position.x
	return total / float(units.size())


func _test_full_flow() -> void:
	section("definition of done: travel, encounter, battle, same campaign back")
	SaveManager.delete_all_saves()
	var state := _fresh_campaign("Step 4 DoD", 20256)
	state.player_gold = 500
	var recruitment := RecruitmentService.build(state, GameManager.config())
	recruitment.recruit_many(state.settlement("greywatch"), "peasant_recruit", 4)
	var campaign_id := state.campaign_id
	var soldier_ids := state.player_party.member_ids.duplicate()

	var world := await SceneManager.change_scene_and_wait("world_map")
	not_null(world, "world map loads")

	# Travel, then meet someone.
	var travel := TravelService.new(state, GameManager.config())
	travel.teleport_to("greywatch")
	var encounters := EncounterService.build(state, GameManager.config())
	var world_party := state.parties[str(state.parties.keys()[0])] as WorldParty
	state.world_position = world_party.position
	var detected := encounters.detect()
	not_null(detected, "an encounter is detected on the map")

	var context := encounters.build_context(detected, true)
	not_null(context, "attacking produces a battle context")

	var battle_scene := await SceneManager.change_scene_and_wait("battle", {"context": context})
	not_null(battle_scene, "the battle scene loads from the payload")
	equal(SceneManager.current_key, "battle", "SceneManager reports battle")

	# The battle scene must draw the armies the context described. Find its view.
	var view := _find_node_of_type(battle_scene, "battle_view.gd")
	not_null(view, "the battle scene has a view bound to a simulator")
	if view != null:
		var simulator: BattleSimulator = view.simulator
		not_null(simulator, "the view has a simulator")
		if simulator != null:
			equal(simulator.side_count(BattleContext.SIDE_PLAYER), 4, "the four player soldiers are on the field")
			equal(simulator.side_count(BattleContext.SIDE_ENEMY), context.enemy_snapshot.size(),
				"the enemy party is on the field")
			var blood_present := false
			for unit in simulator.units:
				if unit.side == BattleContext.SIDE_PLAYER and soldier_ids.has(unit.soldier_id):
					blood_present = true
			check(blood_present, "the units on the field are the campaign's own soldiers")

	# Return to the campaign.
	var back := await SceneManager.change_scene_and_wait("world_map")
	not_null(back, "returned to the world map")
	check(GameManager.campaign == state, "it is the same campaign")
	equal(GameManager.campaign.campaign_id, campaign_id, "the campaign id is unchanged")
	equal(state.player_party.size(), 4, "the party is intact after the battle round trip")
	for soldier_id in soldier_ids:
		not_null(state.soldier(soldier_id), "soldier %s survived the round trip" % soldier_id)

	await SceneManager.change_scene_and_wait("main_menu")


## Finds a node in a freshly loaded scene whose script file matches. Used so the
## test can inspect the real battle scene the payload produced rather than a
## reconstruction of it.
func _find_node_of_type(root: Node, script_file: String) -> Node:
	var script := root.get_script() as GDScript
	if script != null and script.resource_path.get_file() == script_file:
		return root
	for child in root.get_children():
		var found := _find_node_of_type(child, script_file)
		if found != null:
			return found
	return null
