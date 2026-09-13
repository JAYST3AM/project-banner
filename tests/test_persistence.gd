extends TestCase
## Step 6: persistence.
##
## Everything the milestone lists must survive a save and a load: campaign
## metadata, seed, game time, world location, destination, gold, the party, every
## individual soldier with their XP, kills and level, who is dead and who is alive,
## settlement data, recruit pools and enemy parties.
##
## The cross-process half of the milestone - quit the game, relaunch it, press
## Continue - lives in tests/persistence_check.gd, because it needs two real
## processes to be worth anything.

const SEED := 60601


func run() -> void:
	await _tick()
	SaveManager.delete_all_saves()
	_test_everything_round_trips()
	_test_a_fought_battle_round_trips()
	_test_migration_from_an_unversioned_save()
	_test_a_newer_save_is_refused()
	_test_missing_and_corrupt_files()
	SaveManager.delete_all_saves()
	GameManager.end_campaign()


func _fresh_campaign(name: String, recruits: int) -> CampaignState:
	var state := GameManager.new_campaign(name, SEED)
	var builder := WorldBuilder.new(state, GameManager.config())
	builder.build_if_needed()
	var overworld := OverworldService.build(state, GameManager.config())
	overworld.spawn_if_needed()
	if recruits > 0:
		state.player_gold = 5000
		var recruitment := RecruitmentService.build(state, GameManager.config())
		recruitment.recruit_many(state.settlement("greywatch"), "peasant_recruit", recruits)
	return state


func _test_everything_round_trips() -> void:
	section("everything the milestone lists survives a round trip")
	var state := _fresh_campaign("Persistence", 6)
	var config := GameManager.config()

	# Deliberately put the campaign in an unusual-but-legal position.
	state.player_gold = 1234
	state.world_position = Vector2(733.25, 411.5)
	state.destination_id = "brackenford"
	state.current_settlement_id = ""
	state.clock.day = 17
	state.clock.hour = 21.75
	state.clock.set_speed(CampaignClock.Speed.FAST)
	state.flags["custom"] = {"note": "arbitrary nested data", "count": 3}
	var settlement := state.settlement("redmoor")
	settlement.visited = true
	settlement.recruit_pool["peasant_recruit"] = 1
	settlement.last_restock_day = 12
	var soldier := state.party_members(state.player_party)[0]

	check(GameManager.save_campaign(), "the campaign saved")

	var loaded := SaveManager.load_campaign(SaveManager.SLOT_DEFAULT, config)
	not_null(loaded, "the campaign loaded")
	if loaded == null:
		return

	# Campaign metadata
	equal(loaded.campaign_id, state.campaign_id, "campaign id")
	equal(loaded.campaign_name, state.campaign_name, "campaign name")
	equal(loaded.campaign_seed, state.campaign_seed, "campaign seed")
	check(not loaded.created_at.is_empty(), "creation timestamp")
	check(not loaded.last_saved_at.is_empty(), "last-saved timestamp")

	# Time
	equal(loaded.clock.day, 17, "campaign day")
	approx(loaded.clock.hour, 21.75, 0.001, "campaign hour")
	equal(int(loaded.clock.speed), int(CampaignClock.Speed.FAST), "time speed")
	equal(int(loaded.clock.resume_speed), int(CampaignClock.Speed.FAST), "the speed to resume at")

	# Position and destination
	approx(loaded.world_position.x, 733.25, 0.001, "world x")
	approx(loaded.world_position.y, 411.5, 0.001, "world y")
	equal(loaded.destination_id, "brackenford", "destination in progress")
	equal(loaded.current_settlement_id, "", "current settlement")

	# Gold and party
	equal(loaded.player_gold, 1234, "gold")
	equal(loaded.player_party.id, state.player_party.id, "party id")
	equal(loaded.player_party.display_name, state.player_party.display_name, "party name")
	equal(loaded.player_party.member_ids, state.player_party.member_ids, "party membership, in order")
	equal(loaded.party_members(loaded.player_party).size(), 6, "every soldier resolves after a load")

	# Individual soldiers
	var reloaded := loaded.soldier(soldier.id)
	not_null(reloaded, "a specific soldier came back")
	if reloaded != null:
		equal(reloaded.full_name(), soldier.full_name(), "soldier name")
		equal(reloaded.age, soldier.age, "soldier age")
		equal(reloaded.unit_type_id, soldier.unit_type_id, "soldier archetype")
		equal(reloaded.level, soldier.level, "soldier level")
		equal(reloaded.xp, soldier.xp, "soldier experience")
		equal(reloaded.hp, soldier.hp, "soldier hit points")
		equal(reloaded.max_hp, soldier.max_hp, "soldier maximum hit points")
		equal(reloaded.kills, soldier.kills, "soldier kills")
		equal(reloaded.battles_fought, soldier.battles_fought, "battles fought")
		equal(reloaded.battles_survived, soldier.battles_survived, "battles survived")
		equal(reloaded.morale, soldier.morale, "soldier morale")
		equal(reloaded.loyalty, soldier.loyalty, "soldier loyalty")
		equal(reloaded.traits, soldier.traits, "soldier traits")
		equal(reloaded.status, soldier.status, "soldier alive/dead state")
		equal(reloaded.history.size(), soldier.history.size(), "personal history")
		equal(reloaded.history[0].get("text"), soldier.history[0].get("text"), "history wording")

	# Settlements and their pools
	equal(loaded.settlements.size(), 4, "every settlement")
	equal(loaded.roads.size(), 4, "every road")
	var loaded_redmoor := loaded.settlement("redmoor")
	not_null(loaded_redmoor, "a specific settlement came back")
	if loaded_redmoor != null:
		equal(loaded_redmoor.name, "Redmoor", "settlement name")
		equal(loaded_redmoor.type, Settlement.TYPE_VILLAGE, "settlement type")
		equal(loaded_redmoor.population, 420, "settlement population")
		check(loaded_redmoor.visited, "the visited flag survived")
		equal(loaded_redmoor.last_restock_day, 12, "the restock day survived")
		equal(int(loaded_redmoor.recruit_pool.get("peasant_recruit", -1)), 1, "the depleted recruit pool survived")
		approx(loaded_redmoor.position.x, settlement.position.x, 0.001, "settlement position")

	# Enemy parties
	equal(loaded.parties.size(), 3, "every enemy party")
	equal(loaded.enemy_parties.size(), 3, "every enemy roster")
	for key in state.parties.keys():
		var original := state.parties[key] as WorldParty
		var copy := loaded.world_party(str(key))
		not_null(copy, "party %s came back" % key)
		if copy == null:
			continue
		equal(copy.display_name, original.display_name, "party %s name" % key)
		approx(copy.position.x, original.position.x, 0.001, "party %s position" % key)
		approx(copy.home_position.x, original.home_position.x, 0.001, "party %s home" % key)
		equal(copy.wander_count, original.wander_count, "party %s wander count" % key)
		equal(copy.defeated, original.defeated, "party %s defeated flag" % key)
		var original_roster := state.party_members(state.party_of(original))
		var copy_roster := loaded.party_members(loaded.party_of(copy))
		equal(copy_roster.size(), original_roster.size(), "party %s roster size" % key)
		for index in mini(copy_roster.size(), original_roster.size()):
			equal(copy_roster[index].full_name(), original_roster[index].full_name(),
				"party %s soldier %d name" % [key, index])

	# The arbitrary extension bag
	var custom: Variant = loaded.flags.get("custom", null)
	not_null(custom, "the flags bag survived")
	if typeof(custom) == TYPE_DICTIONARY:
		equal(str((custom as Dictionary).get("note", "")), "arbitrary nested data", "nested flag data survived")
		equal(int((custom as Dictionary).get("count", 0)), 3, "nested flag numbers survived")

	# The next generated soldier id must not collide with a loaded one.
	var next_id := loaded.next_soldier_id()
	is_null(loaded.soldier(next_id), "the next soldier id is unused")

	# And a second save/load cycle must be stable (no drift on repeated saves).
	check(SaveManager.save_campaign(loaded), "saving a loaded campaign works")
	var twice := SaveManager.load_campaign(SaveManager.SLOT_DEFAULT, config)
	not_null(twice, "it loads again")
	if twice != null:
		equal(twice.to_dict().size(), loaded.to_dict().size(), "the save shape is stable across a resave")
		equal(twice.player_gold, loaded.player_gold, "gold is stable across a resave")
		equal(twice.soldiers.size(), loaded.soldiers.size(), "no soldiers appear on a resave")


func _test_a_fought_battle_round_trips() -> void:
	section("a fought battle survives a restart")
	var state := _fresh_campaign("Battle Persistence", 5)
	var config := GameManager.config()
	var encounters := EncounterService.build(state, config)
	var earliest := float(INF)
	var world_party: WorldParty = null
	for key in state.parties.keys():
		var candidate := state.parties[key] as WorldParty
		if candidate != null and candidate.is_available():
			var strength := state.active_members(state.party_of(candidate)).size()
			if float(strength) < earliest:
				earliest = float(strength)
				world_party = candidate
	not_null(world_party, "a party to fight")
	if world_party == null:
		return

	state.world_position = world_party.position
	var context := encounters.build_context(world_party, true)
	var simulator := BattleSimulator.new(config, context.battle_seed)
	simulator.add_units(BattleSetup.build_units_prepared(context, config))
	simulator.start()
	var guard := 0
	while not simulator.is_finished() and guard < 40000:
		guard += 1
		simulator.step(0.05)

	var resolver := BattleResolver.build(state, config)
	var result := resolver.build_result(context, simulator, simulator.winner, simulator.elapsed, false)
	resolver.apply(result, context)

	# Remember what the campaign says immediately after the fight.
	var gold_after := state.player_gold
	var dead_ids: Array[String] = []
	var survivor_ids: Array[String] = []
	for member_id in state.player_party.member_ids:
		var soldier := state.soldier(member_id)
		if soldier == null:
			continue
		if soldier.status == Soldier.STATUS_DEAD:
			dead_ids.append(soldier.id)
		else:
			survivor_ids.append(soldier.id)
	var kills_before := 0
	var xp_before := 0
	for member_id in state.player_party.member_ids:
		var soldier := state.soldier(member_id)
		if soldier != null:
			kills_before += soldier.kills
			xp_before += soldier.xp

	check(GameManager.save_campaign(), "the campaign saved after the battle")
	var loaded := SaveManager.load_campaign(SaveManager.SLOT_DEFAULT, config)
	not_null(loaded, "it reloads")
	if loaded == null:
		return

	equal(loaded.player_gold, gold_after, "gold after the battle")
	var kills_after := 0
	var xp_after := 0
	var dead_after := 0
	for member_id in loaded.player_party.member_ids:
		var soldier := loaded.soldier(member_id)
		if soldier == null:
			continue
		kills_after += soldier.kills
		xp_after += soldier.xp
		if soldier.status == Soldier.STATUS_DEAD:
			dead_after += 1
	equal(kills_after, kills_before, "kill counts after the battle")
	equal(xp_after, xp_before, "experience after the battle")
	equal(dead_after, dead_ids.size(), "casualties after the battle")
	for soldier_id in dead_ids:
		var soldier := loaded.soldier(soldier_id)
		not_null(soldier, "a fallen soldier came back")
		if soldier != null:
			equal(soldier.status, Soldier.STATUS_DEAD, "they are still dead")
			equal(soldier.hp, 0, "they are still on zero hit points")
			check(soldier.history.size() > 0, "their history came back")
	equal(loaded.active_members(loaded.player_party).size(), survivor_ids.size(),
		"only the survivors are fielded after a reload")

	# The chronicle and the world state must agree with what happened.
	var loaded_resolver := BattleResolver.build(loaded, config)
	var summary := loaded_resolver.last_battle_summary()
	check(not summary.is_empty(), "the battle chronicle came back")
	if not summary.is_empty():
		equal(str(summary.get("battle_id", "")), result.battle_id, "the chronicle names the battle")
		equal(int(summary.get("enemy_dead", 0)), result.enemy_dead.size(), "the chronicle's enemy losses")
		equal(int(summary.get("player_dead", 0)), result.player_dead.size(), "the chronicle's own losses")
	if result.player_won():
		check(not loaded.world_party(world_party.id).is_available(),
			"the destroyed party is still destroyed after a reload")

	# And the battle counter is not reused, so the next fight is a new battle.
	var next_context := encounters.build_context(world_party, true)
	not_equal(next_context.battle_id, result.battle_id, "a later battle gets a new id")


func _test_migration_from_an_unversioned_save() -> void:
	section("an unversioned save migrates")
	var state := _fresh_campaign("Migration", 2)
	check(GameManager.save_campaign(), "a normal save was written")

	# Rewrite the file the way an early build would have: version field removed,
	# party membership stored as a bare array.
	var path := SaveManager.slot_path()
	var raw := JSON.parse_string(FileAccess.get_file_as_string(path)) as Dictionary
	raw.erase("save_version")
	var members: Array = ((raw.get("player_party", {}) as Dictionary).get("member_ids", []) as Array)
	raw["player_party"] = members
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(raw, "\t"))
	file.close()

	var loaded := SaveManager.load_campaign(SaveManager.SLOT_DEFAULT, GameManager.config())
	not_null(loaded, "the old-format save loaded")
	if loaded == null:
		return
	equal(loaded.player_party.member_ids.size(), members.size(), "the migrated party kept its members")
	equal(loaded.party_members(loaded.player_party).size(), members.size(), "the migrated party resolves")


func _test_a_newer_save_is_refused() -> void:
	section("a save from a newer build is refused, not misread")
	var state := _fresh_campaign("Too New", 0)
	check(GameManager.save_campaign(), "a normal save was written")

	var path := SaveManager.slot_path()
	var raw := JSON.parse_string(FileAccess.get_file_as_string(path)) as Dictionary
	raw["save_version"] = SaveManager.SAVE_VERSION + 1
	raw["campaign_name"] = "From The Future"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(raw, "\t"))
	file.close()

	check(SaveManager.is_save_too_new(), "the save is identified as coming from a newer build")
	is_null(SaveManager.load_campaign(SaveManager.SLOT_DEFAULT, GameManager.config()),
		"loading it is refused rather than silently discarding fields")
	# The menu must still be able to describe it, so the player knows why.
	var meta := SaveManager.peek_metadata()
	equal(meta.get("campaign_name"), "From The Future", "the menu can still read its name")
	greater(float(meta.get("save_version", 0)), float(SaveManager.SAVE_VERSION),
		"and the version it needs")
	equal(GameManager.continue_campaign(), false, "Continue refuses it")


func _test_missing_and_corrupt_files() -> void:
	section("missing and corrupt saves")
	SaveManager.delete_all_saves()
	await _tick()
	check(not SaveManager.has_save(), "no save exists")
	is_null(SaveManager.load_campaign(SaveManager.SLOT_DEFAULT, GameManager.config()),
		"loading a missing save returns null instead of crashing")
	equal(SaveManager.peek_metadata(), {}, "peeking at a missing save returns nothing")

	SaveManager.ensure_dir()
	var file := FileAccess.open(SaveManager.slot_path(), FileAccess.WRITE)
	file.store_string("{ this is not json ")
	file.close()
	check(SaveManager.has_save(), "the corrupt file is present")
	is_null(SaveManager.load_campaign(SaveManager.SLOT_DEFAULT, GameManager.config()),
		"loading a corrupt save returns null instead of crashing")
	equal(SaveManager.peek_metadata(), {}, "peeking at a corrupt save returns nothing")

	# A half-written document (valid JSON, missing everything) must still load as
	# an empty campaign rather than throwing.
	file = FileAccess.open(SaveManager.slot_path(), FileAccess.WRITE)
	file.store_string("{\"save_version\": 1}")
	file.close()
	var bare := SaveManager.load_campaign(SaveManager.SLOT_DEFAULT, GameManager.config())
	not_null(bare, "a document with nothing in it still loads")
	if bare != null:
		equal(bare.player_party.member_ids.size(), 0, "an empty party")
		equal(bare.settlements.size(), 0, "an empty world, which the builder will repopulate")
		equal(bare.clock.day, 1, "a default day")
