extends TestCase
## Step 3 checks: unit data, procedural names, the soldier factory, the
## recruitment transaction, and the milestone's own definition of done - a
## soldier recruited in a town is still there after leaving, travelling and
## returning.


func run() -> void:
	await _tick()
	SaveManager.delete_all_saves()
	_test_catalogs()
	_test_names()
	_test_factory()
	_test_recruitment_rules()
	_test_recruitment_transaction()
	_test_recruit_many_and_limits()
	_test_soldiers_survive_travel_and_save()
	await _test_definition_of_done()
	SaveManager.delete_all_saves()
	GameManager.end_campaign()


func _fresh_campaign(name: String, seed_value: int) -> CampaignState:
	var state := GameManager.new_campaign(name, seed_value)
	var builder := WorldBuilder.new(state, GameManager.config())
	builder.build_if_needed()
	return state


func _test_catalogs() -> void:
	section("unit and trait data")
	var units := UnitCatalog.load_from()
	equal(units.load_errors.size(), 0, "unit catalog loads without errors")
	equal(units.definitions.size(), 3, "three archetypes defined")

	for unit_type_id in ["peasant_recruit", "spearman", "archer"]:
		check(units.has(unit_type_id), "%s exists" % unit_type_id)
		var definition := units.get_definition(unit_type_id)
		not_null(definition, "%s resolves to a definition" % unit_type_id)
		if definition == null:
			continue
		greater(definition.hp, 0, "%s has hit points" % unit_type_id)
		greater(definition.attack, 0, "%s has attack" % unit_type_id)
		greater(definition.recruit_cost, 0, "%s costs gold" % unit_type_id)
		greater(definition.move_speed, 0.0, "%s can move" % unit_type_id)
		check(not definition.display_name.is_empty(), "%s has a display name" % unit_type_id)
		check(not definition.description.is_empty(), "%s has a description" % unit_type_id)

	var peasant := units.get_definition("peasant_recruit")
	var spearman := units.get_definition("spearman")
	var archer := units.get_definition("archer")
	less(float(peasant.hp), float(spearman.hp), "recruits are frailer than spearmen")
	less(float(peasant.recruit_cost), float(spearman.recruit_cost), "recruits are cheaper than spearmen")
	check(archer.ranged, "the archer is a ranged unit")
	check(not spearman.ranged, "the spearman is not ranged")
	greater(archer.attack_range, spearman.attack_range, "the archer outranges the spearman")
	equal(peasant.upgrade_to, "spearman", "the recruit's upgrade path points at the spearman")

	# Progression curve is applied by the definition, not scattered.
	var config := GameManager.config()
	equal(peasant.max_hp_at(1, config), peasant.hp, "level 1 hit points equal the base value")
	greater(float(peasant.max_hp_at(3, config)), float(peasant.max_hp_at(1, config)), "veterans have more hit points")
	greater(float(peasant.attack_at(3, config)), float(peasant.attack_at(1, config)), "veterans hit harder")

	var traits := TraitCatalog.load_from()
	greater(float(traits.definitions.size()), 0.0, "traits load from data")
	check(traits.has("cowardly"), "the cowardly trait exists")
	check(traits.has("brave"), "the brave trait exists")
	check(not traits.ids_with_polarity("positive").is_empty(), "some traits are positive")
	check(not traits.ids_with_polarity("negative").is_empty(), "some traits are negative")
	less(float(traits.total_modifier(["cowardly"] as Array[String], "morale")), 0.0,
		"the cowardly trait lowers morale")
	greater(float(traits.total_modifier(["brave"] as Array[String], "morale")), 0.0,
		"the brave trait raises morale")


func _test_names() -> void:
	section("procedural names")
	var state := _fresh_campaign("Name Test", 1111)
	var names := NameGenerator.load_from(state.rng)
	check(names.is_usable(), "name generator is usable")

	var taken := {}
	var first_pass: Array[String] = []
	for index in 8:
		var rolled := names.name_for(index, taken)
		var full := "%s %s" % [rolled.get("first_name", ""), rolled.get("surname", "")]
		check(not full.strip_edges().is_empty(), "soldier %d gets a name" % index)
		check(not taken.has(full), "name '%s' is unique" % full)
		taken[full] = true
		first_pass.append(full)

	# Deterministic: regenerating the same indices yields the same names, which is
	# what makes a campaign seed reproducible.
	var second_generator := NameGenerator.load_from(RngService.new(1111))
	var taken_again := {}
	var second_pass: Array[String] = []
	for index in 8:
		var rolled := second_generator.name_for(index, taken_again)
		var full := "%s %s" % [rolled.get("first_name", ""), rolled.get("surname", "")]
		taken_again[full] = true
		second_pass.append(full)
	equal(first_pass, second_pass, "the same seed produces the same names")

	# A different seed must not produce an identical run of names.
	var other_generator := NameGenerator.load_from(RngService.new(2222))
	var taken_other := {}
	var other_pass: Array[String] = []
	for index in 8:
		var rolled := other_generator.name_for(index, taken_other)
		var full := "%s %s" % [rolled.get("first_name", ""), rolled.get("surname", "")]
		taken_other[full] = true
		other_pass.append(full)
	not_equal(first_pass, other_pass, "a different seed produces different names")

	# Age rolls must stay inside the configured band.
	var config := GameManager.config()
	for index in 12:
		var age := names.value_for(index, "age", config.get_int("recruitment.min_age", 17), config.get_int("recruitment.max_age", 33))
		check(age >= config.get_int("recruitment.min_age", 17), "age is at least the minimum")
		check(age <= config.get_int("recruitment.max_age", 33), "age is at most the maximum")


func _test_factory() -> void:
	section("soldier factory")
	var state := _fresh_campaign("Factory Test", 2222)
	var config := GameManager.config()
	var factory := SoldierFactory.build(state, config)
	not_null(factory, "factory builds")

	var units := UnitCatalog.load_from()
	var created := factory.create("peasant_recruit", 1, "Greywatch")
	check(bool(created.get("ok", false)), "a soldier is created")
	var soldier := created.get("soldier", null) as Soldier
	not_null(soldier, "the created soldier exists")
	if soldier == null:
		return
	check(soldier.id.is_empty(), "the factory does not assign an id (the campaign does)")
	check(not soldier.first_name.is_empty(), "the soldier has a first name")
	check(not soldier.surname.is_empty(), "the soldier has a surname")
	equal(soldier.unit_type_id, "peasant_recruit", "the unit type is recorded")
	equal(soldier.level, 1, "recruits start at level 1")
	equal(soldier.xp, 0, "recruits start with no experience")
	equal(soldier.kills, 0, "recruits start with no kills")
	equal(soldier.battles_fought, 0, "recruits start with no battles")
	equal(soldier.status, Soldier.STATUS_ACTIVE, "recruits start active")
	check(soldier.age >= config.get_int("recruitment.min_age", 17), "age is in band")
	check(soldier.age <= config.get_int("recruitment.max_age", 33), "age is in band")
	greater(float(soldier.max_hp), 0.0, "the soldier has hit points")
	equal(soldier.hp, soldier.max_hp, "recruits start at full health")
	equal(soldier.history.size(), 1, "the recruitment is recorded in the soldier's history")
	contains(str(soldier.history[0].get("text", "")), "Greywatch", "the history names the town")

	# Trait modifiers must actually change the starting numbers, or the trait data
	# is decoration.
	var traits := TraitCatalog.load_from()
	for trait_id in soldier.traits:
		var modifiers := traits.modifiers(trait_id)
		if modifiers.has("morale"):
			var expected := clampi(
				config.get_int("recruitment.base_morale", 60) + int(modifiers["morale"]), 0, 100)
			if soldier.traits.size() == 1:
				equal(soldier.morale, expected, "'%s' shifted starting morale" % trait_id)
		if modifiers.has("hp_pct") and soldier.traits.size() == 1:
			var base_hp := units.get_definition("peasant_recruit").hp
			var scaled := int(round(float(base_hp) * (1.0 + float(modifiers["hp_pct"]) / 100.0)))
			equal(soldier.max_hp, maxi(1, scaled), "'%s' scaled starting hit points" % trait_id)

	check(soldier.traits.size() >= config.get_int("progression.trait_rolls_min", 1), "at least one trait rolled")
	check(soldier.traits.size() <= config.get_int("progression.trait_rolls_max", 2), "no more than the maximum traits rolled")

	# Unknown archetypes must be refused, not silently accepted.
	var bad := factory.create("dragon", 2, "Greywatch")
	check(not bool(bad.get("ok", false)), "an unknown archetype is refused")
	is_null(bad.get("soldier", null), "no soldier is produced for an unknown archetype")

	# Higher-level soldiers have more hit points.
	var spearman := units.get_definition("spearman")
	greater(float(spearman.max_hp_at(5, config)), float(spearman.max_hp_at(1, config)),
		"the progression curve raises hit points with level")


func _test_recruitment_rules() -> void:
	section("recruitment rules")
	var state := _fresh_campaign("Rules Test", 3333)
	var config := GameManager.config()
	var recruitment := RecruitmentService.build(state, config)
	var greywatch := state.settlement("greywatch")

	check(recruitment.available_at(greywatch, "peasant_recruit") > 0, "greywatch has recruits to offer")
	equal(recruitment.cost_for("peasant_recruit"), 20, "recruit cost comes from unit data")
	equal(recruitment.max_party_size(), config.get_int("campaign.max_party_size", 24), "party limit from config")

	# Standing in the town: allowed.
	check(bool(recruitment.can_recruit(greywatch, "peasant_recruit").get("ok", false)),
		"recruiting works while standing in the town")

	# Not standing there: refused, with a readable reason.
	state.current_settlement_id = ""
	var away := recruitment.can_recruit(greywatch, "peasant_recruit")
	check(not bool(away.get("ok", false)), "recruiting away from the town is refused")
	contains(str(away.get("message", "")), "Greywatch", "the refusal tells you which town to travel to")

	# Unknown archetype.
	state.current_settlement_id = "greywatch"
	check(not bool(recruitment.can_recruit(greywatch, "dragon").get("ok", false)),
		"an unknown archetype is refused")

	# Exhausted pool.
	var drained := Settlement.new()
	drained.id = "greywatch"
	drained.name = "Greywatch"
	drained.recruit_pool = {"peasant_recruit": 0}
	check(not bool(recruitment.can_recruit(drained, "peasant_recruit").get("ok", false)),
		"an empty pool is refused")
	check(str(recruitment.can_recruit(drained, "peasant_recruit").get("message", "")).contains("No "),
		"the empty-pool message reads as plain English")

	# Not enough gold.
	state.player_gold = 5
	var poor := recruitment.can_recruit(greywatch, "peasant_recruit")
	check(not bool(poor.get("ok", false)), "recruiting without the gold is refused")
	contains(str(poor.get("message", "")), "20", "the refusal says how much is needed")
	contains(str(poor.get("message", "")), "5", "the refusal says how much you have")


func _test_recruitment_transaction() -> void:
	section("recruitment transaction")
	var state := _fresh_campaign("Transaction Test", 4444)
	var recruitment := RecruitmentService.build(state, GameManager.config())
	var greywatch := state.settlement("greywatch")
	var units := recruitment.units

	var gold_before := state.player_gold
	var pool_before := recruitment.available_at(greywatch, "peasant_recruit")
	var party_before := state.player_party.size()
	var soldiers_before := state.soldiers.size()

	var result := recruitment.recruit(greywatch, "peasant_recruit")
	check(bool(result.get("ok", false)), "the recruit is accepted")
	var soldier := result.get("soldier", null) as Soldier
	not_null(soldier, "a soldier came back")
	if soldier == null:
		return

	equal(state.player_gold, gold_before - 20, "the cost was deducted once")
	equal(recruitment.available_at(greywatch, "peasant_recruit"), pool_before - 1,
		"the town's pool went down by one")
	equal(state.player_party.size(), party_before + 1, "the party grew by one")
	equal(state.soldiers.size(), soldiers_before + 1, "the campaign registry grew by one")
	check(state.player_party.has_member(soldier.id), "the soldier is a member of the player party")
	check(state.soldier(soldier.id) == soldier, "the registry returns the same soldier object")
	check(not soldier.id.is_empty(), "the campaign assigned the soldier an id")

	var members := state.party_members(state.player_party)
	equal(members.size(), 1, "the party resolves its member ids to soldiers")
	check(members[0] == soldier, "the resolved member is the recruited soldier")

	# The unit type in the roster must be a real, known archetype.
	check(units.has(soldier.unit_type_id), "the recruited soldier has a known archetype")

	# A refusal must not change anything.
	state.player_gold = 0
	var refused := recruitment.recruit(greywatch, "peasant_recruit")
	check(not bool(refused.get("ok", false)), "recruiting with no gold is refused")
	equal(state.player_party.size(), party_before + 1, "a refused recruit does not grow the party")
	equal(recruitment.available_at(greywatch, "peasant_recruit"), pool_before - 1,
		"a refused recruit does not change the pool")


func _test_recruit_many_and_limits() -> void:
	section("batch recruiting and party limits")
	var state := _fresh_campaign("Batch Test", 5555)
	var config := GameManager.config()
	var recruitment := RecruitmentService.build(state, config)
	var greywatch := state.settlement("greywatch")
	state.player_gold = 10000

	# Batch stops when the pool runs out.
	var pool := recruitment.available_at(greywatch, "peasant_recruit")
	var batch := recruitment.recruit_many(greywatch, "peasant_recruit", pool + 5)
	equal((batch.get("recruited", []) as Array).size(), pool, "the batch stops at the pool limit")
	equal(recruitment.available_at(greywatch, "peasant_recruit"), 0, "the pool is exhausted")
	check(not str(batch.get("message", "")).is_empty(), "a partial batch explains why it stopped")

	# Party limit is enforced, across every town in the world.
	var full := _fresh_campaign("Limit Test", 6666)
	var full_recruitment := RecruitmentService.build(full, config)
	var full_travel := TravelService.new(full, config)
	full.player_gold = 100000
	var capacity := full_recruitment.max_party_size()
	var recruited_total := 0
	var stops := 0
	for settlement_id in ["greywatch", "brackenford", "redmoor"]:
		full_travel.teleport_to(settlement_id)
		var town := full.settlement(settlement_id)
		not_null(town, "test town %s exists" % settlement_id)
		if town == null:
			continue
		for unit_type_id in full_recruitment.units.ids():
			var outcome := full_recruitment.recruit_many(town, unit_type_id, 30)
			recruited_total += (outcome.get("recruited", []) as Array).size()
			if full_recruitment.party_capacity_remaining() == 0:
				stops += 1
	equal(full.player_party.size(), capacity, "the party never exceeds the configured limit")
	equal(recruited_total, capacity, "every accepted recruit landed in the party")
	equal(full_recruitment.party_capacity_remaining(), 0, "no capacity remains")
	greater(float(stops), 0.0, "at least one recruitment stopped because the party was full")

	full_travel.teleport_to("greywatch")
	var over := full_recruitment.can_recruit(full.settlement("greywatch"), "peasant_recruit")
	check(not bool(over.get("ok", false)), "recruiting into a full party is refused")
	contains(str(over.get("message", "")), "full", "the refusal says the party is full")


func _test_soldiers_survive_travel_and_save() -> void:
	section("soldiers survive travel and saving")
	var state := _fresh_campaign("Survive Test", 7777)
	var travel := TravelService.new(state, GameManager.config())
	var recruitment := RecruitmentService.build(state, GameManager.config())
	var greywatch := state.settlement("greywatch")
	state.player_gold = 500

	var batch := recruitment.recruit_many(greywatch, "peasant_recruit", 3)
	var recruited := batch.get("recruited", []) as Array
	equal(recruited.size(), 3, "three soldiers recruited")
	var ids: Array[String] = []
	for soldier in recruited:
		ids.append((soldier as Soldier).id)

	# Leave town, travel, come back.
	var redmoor := state.settlement("redmoor")
	travel.set_destination("redmoor")
	check(travel.is_travelling(), "set out for redmoor")
	var guard := 0
	while travel.is_travelling() and guard < 100:
		guard += 1
		travel.step(1.0)
	check(travel.is_at_settlement("redmoor"), "arrived at redmoor")
	equal(state.player_party.size(), 3, "the party is intact after travelling")

	# Save and reload.
	check(GameManager.save_campaign(), "saved with soldiers in the party")
	var restored := SaveManager.load_campaign(SaveManager.SLOT_DEFAULT, GameManager.config())
	not_null(restored, "campaign reloads")
	if restored == null:
		return
	equal(restored.player_party.size(), 3, "the party came back with three soldiers")
	for soldier_id in ids:
		var survivor := restored.soldier(soldier_id)
		not_null(survivor, "soldier %s came back" % soldier_id)
		if survivor == null:
			continue
		check(not survivor.first_name.is_empty(), "the restored soldier still has a name")
		check(survivor.traits.size() > 0, "the restored soldier kept their traits")
		check(survivor.history.size() > 0, "the restored soldier kept their history")
		equal(survivor.status, Soldier.STATUS_ACTIVE, "the restored soldier is still active")
	# Ids must not be reused after a load.
	check(not restored.next_soldier_id().is_empty(), "a new id is still available after loading")


func _test_definition_of_done() -> void:
	section("definition of done: enter town, recruit, leave, travel, return")
	SaveManager.delete_all_saves()
	var state := _fresh_campaign("Step 3 DoD", 8888)
	state.player_gold = 400

	var world := await SceneManager.change_scene_and_wait("world_map")
	not_null(world, "world map loads")
	var town := await SceneManager.change_scene_and_wait("settlement", {"settlement_id": "greywatch"})
	not_null(town, "settlement screen loads")

	var recruitment := RecruitmentService.build(state, GameManager.config())
	var greywatch := state.settlement("greywatch")
	var result := recruitment.recruit_many(greywatch, "peasant_recruit", 3)
	var recruited := result.get("recruited", []) as Array
	equal(recruited.size(), 3, "three soldiers recruited in town")
	var soldier := recruited[0] as Soldier
	var soldier_id := soldier.id
	var soldier_name := soldier.full_name()

	# View the soldier - the record the roster shows must be complete.
	greater(float(soldier.max_hp), 0.0, "the soldier can be inspected: hit points")
	check(soldier.hp <= soldier.max_hp, "the soldier can be inspected: health")
	greater(soldier.xp_to_next(GameManager.config()), 0, "the soldier can be inspected: xp to next level")
	equal(soldier.level, 1, "the soldier can be inspected: level")

	# Leave town, travel to another town, come back.
	var back_to_map := await SceneManager.change_scene_and_wait("world_map", {"select_settlement_id": "greywatch"})
	not_null(back_to_map, "left town back to the world map")

	var travel := TravelService.new(state, GameManager.config())
	travel.set_destination("brackenford")
	check(travel.is_travelling(), "travelling to brackenford")
	var guard := 0
	while travel.is_travelling() and guard < 200:
		guard += 1
		travel.step(1.0)
	check(travel.is_at_settlement("brackenford"), "arrived at brackenford")
	equal(state.player_party.size(), 3, "the soldiers travelled with the party")

	var other_town := await SceneManager.change_scene_and_wait("settlement", {"settlement_id": "brackenford"})
	not_null(other_town, "entered brackenford")
	equal(state.player_party.size(), 3, "the soldiers are in the party at brackenford")

	travel.set_destination("greywatch")
	guard = 0
	while travel.is_travelling() and guard < 200:
		guard += 1
		travel.step(1.0)
	var home := await SceneManager.change_scene_and_wait("settlement", {"settlement_id": "greywatch"})
	not_null(home, "returned to greywatch")

	var still_there := state.soldier(soldier_id)
	not_null(still_there, "the soldier still exists after the round trip")
	if still_there != null:
		equal(still_there.full_name(), soldier_name, "it is the same soldier, not a replacement")
		equal(still_there.status, Soldier.STATUS_ACTIVE, "the soldier is still active")
		check(state.player_party.has_member(soldier_id), "the soldier is still in the party")

	await SceneManager.change_scene_and_wait("main_menu")
