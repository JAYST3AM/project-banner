extends TestCase
## Step 2 checks: the world is built from data, travel moves the party and spends
## game time, arrival works, and the debug panel is available without being able
## to corrupt anything on its own.


func run() -> void:
	await _tick()
	SaveManager.delete_all_saves()
	_test_world_builder()
	_test_travel()
	_test_arrival_and_enter()
	_test_speed_states()
	_test_world_survives_save_load()
	await _test_scene_flow()
	SaveManager.delete_all_saves()
	GameManager.end_campaign()


func _fresh_campaign(name: String, seed_value: int) -> CampaignState:
	var state := GameManager.new_campaign(name, seed_value)
	var builder := WorldBuilder.new(state, GameManager.config())
	builder.build_if_needed()
	return state


func _test_world_builder() -> void:
	section("world builder")
	var state := _fresh_campaign("World Test", 1234)
	equal(state.settlements.size(), 4, "four settlements built from data")
	check(state.settlement("greywatch") != null, "greywatch exists")
	check(state.settlement("brackenford") != null, "brackenford exists")
	check(state.settlement("redmoor") != null, "redmoor exists")
	check(state.settlement("thornwood_hollow") != null, "thornwood hollow exists")
	equal(state.roads.size(), 4, "four roads built from data")

	var greywatch := state.settlement("greywatch")
	equal(greywatch.name, "Greywatch", "settlement name from data")
	equal(greywatch.type, Settlement.TYPE_TOWN, "greywatch is a town")
	equal(greywatch.population, 1800, "population from data")
	check(greywatch.recruit_pool_base.has("spearman"), "recruit pool base seeded from data")
	check(not greywatch.description.is_empty(), "description from data")

	var hollow := state.settlement("thornwood_hollow")
	equal(hollow.type, Settlement.TYPE_WILDERNESS, "thornwood hollow is wilderness")
	check(not hollow.is_enterable(), "wilderness is not enterable")
	check(greywatch.is_enterable(), "towns are enterable")

	# The party must start somewhere real.
	var start := state.settlement("greywatch")
	approx(state.world_position.x, start.position.x, 0.001, "party starts at the configured settlement")
	equal(state.current_settlement_id, "greywatch", "party is recorded as being at the start settlement")

	# Building twice must not duplicate or reset the world.
	var builder := WorldBuilder.new(state, GameManager.config())
	check(not builder.build_if_needed(), "build_if_needed is a no-op once the world exists")
	equal(state.settlements.size(), 4, "settlement count unchanged after a second call")

	# Roads must reference real settlements.
	for road in state.roads:
		check(state.settlement(str(road.get("a", ""))) != null, "road start resolves")
		check(state.settlement(str(road.get("b", ""))) != null, "road end resolves")


func _test_travel() -> void:
	section("travel")
	var state := _fresh_campaign("Travel Test", 2345)
	var config := GameManager.config()
	var travel := TravelService.new(state, config)

	var brackenford := state.settlement("brackenford")
	check(not travel.is_travelling(), "not travelling before an order")
	check(not travel.is_at_settlement("brackenford"), "not at brackenford at the start")

	var start_position := state.world_position
	check(travel.set_destination("brackenford"), "destination accepted")
	check(travel.is_travelling(), "now travelling")
	equal(state.destination_id, "brackenford", "destination recorded on the campaign")
	equal(state.current_settlement_id, "", "leaving the settlement clears 'current settlement'")

	var distance := travel.distance_to(brackenford.position)
	greater(distance, 0.0, "destination is some distance away")
	var expected_hours := distance / travel.speed_units_per_game_hour()
	approx(travel.hours_to_reach(brackenford.position), expected_hours, 0.001, "eta matches distance / pace")

	# One hour of travel moves exactly pace * 1 hour.
	var pace := travel.speed_units_per_game_hour()
	var report := travel.step(1.0)
	check(bool(report.get("moved", false)), "step reports movement")
	approx(travel.distance_to(brackenford.position), distance - pace, 0.5, "one game hour covers exactly one hour of pace")
	check(travel.distance_to(brackenford.position) > 0.0, "not there yet")

	# A zero-length step must not be treated as movement.
	var before := state.world_position
	travel.step(0.0)
	approx(state.world_position.distance_to(before), 0.0, 0.0001, "zero game hours moves nothing")

	# Cancelling stops the party.
	travel.clear_destination()
	check(not travel.is_travelling(), "clear_destination stops travel")
	travel.step(5.0)
	approx(state.world_position.distance_to(before), 0.0, 0.0001, "a stopped party does not drift")

	# Ordering a move you are already standing at must be a no-op, and must not
	# cancel a different journey already under way.
	travel.teleport_to("greywatch")
	travel.set_destination("brackenford")
	check(travel.is_travelling(), "journey started")
	check(travel.set_destination("greywatch") == false, "cannot travel to where you already are")
	check(travel.is_travelling(), "the no-op order did not cancel the journey in progress")
	equal(state.destination_id, "brackenford", "destination unchanged by the no-op order")
	travel.clear_destination()

	# Party size slows the column but never below the configured floor.
	var light_pace := travel.speed_units_per_game_hour()
	for i in 10:
		var s := Soldier.new()
		s.unit_type_id = "peasant_recruit"
		s.max_hp = 30
		s.hp = 30
		state.register_soldier(s)
		state.player_party.add_member(s.id)
	var heavy_pace := travel.speed_units_per_game_hour()
	less(heavy_pace, light_pace, "a bigger party travels more slowly")
	var floor_fraction := config.get_float("travel.min_speed_fraction", 0.55)
	greater(heavy_pace, light_pace * floor_fraction - 0.001, "pace never drops below the configured floor")
	check(travel.set_destination("not_a_real_place") == false, "unknown destination rejected")
	check(travel.set_destination("thornwood_hollow") == false, "wilderness is not a travel destination")


func _test_arrival_and_enter() -> void:
	section("arrival")
	var state := _fresh_campaign("Arrival Test", 3456)
	var travel := TravelService.new(state, GameManager.config())
	var redmoor := state.settlement("redmoor")

	travel.set_destination("redmoor")
	var hours := travel.hours_to_reach(redmoor.position)
	var arrived := false
	var guard := 0
	while not arrived and guard < 50:
		guard += 1
		var report := travel.step(hours / 4.0)
		arrived = bool(report.get("arrived", false))
	check(arrived, "arrival reported within a sane number of steps")
	check(travel.is_at_settlement("redmoor"), "party is at redmoor after arriving")
	equal(state.current_settlement_id, "redmoor", "current settlement updated on arrival")
	equal(state.destination_id, "", "destination cleared on arrival")
	approx(state.world_position.x, redmoor.position.x, 0.001, "party lands exactly on the settlement")
	check(redmoor.visited, "arrival marks the settlement visited")
	check(guard < 50, "arrival did not take an unreasonable number of steps")

	travel.teleport_to("brackenford")
	check(travel.is_at_settlement("brackenford"), "teleport puts the party at the settlement")
	equal(state.world_position, state.settlement("brackenford").position, "teleport sets exact coordinates")


func _test_speed_states() -> void:
	section("time and speed states")
	var state := _fresh_campaign("Clock Test", 4567)
	var clock := state.clock
	clock.set_speed(CampaignClock.Speed.NORMAL)
	var day_before := clock.day
	var hour_before := clock.hour

	# Two real seconds at normal speed is one game hour.
	var advanced := clock.advance_real_seconds(2.0)
	approx(advanced, 1.0, 0.001, "normal speed: 2 real seconds = 1 game hour")

	clock.set_speed(CampaignClock.Speed.FAST)
	advanced = clock.advance_real_seconds(2.0)
	approx(advanced, 3.0, 0.001, "fast speed: 2 real seconds = 3 game hours")

	clock.set_speed(CampaignClock.Speed.PAUSED)
	advanced = clock.advance_real_seconds(2.0)
	approx(advanced, 0.0, 0.001, "paused: no game time passes")
	approx(clock.hour, hour_before + 4.0, 0.001, "only the unpaused advances applied")
	equal(clock.day, day_before, "no day rollover in this test")

	check(clock.set_speed_by_name("fast"), "speed can be set by name")
	equal(clock.speed_name(), "Fast", "speed name reflects the setting")
	check(not clock.set_speed_by_name("ludicrous"), "unknown speed names are rejected")
	clock.toggle_pause()
	equal(clock.speed_name(), "Paused", "toggle_pause pauses")
	clock.toggle_pause()
	equal(clock.speed_name(), "Fast", "toggle_pause restores")


func _test_world_survives_save_load() -> void:
	section("world persistence")
	var state := _fresh_campaign("Persist Test", 5678)
	var travel := TravelService.new(state, GameManager.config())
	travel.set_destination("brackenford")
	travel.step(2.0)
	var position := state.world_position
	var visited_redmoor := state.settlement("redmoor")
	visited_redmoor.visited = true
	state.player_gold = 640

	check(GameManager.save_campaign(), "campaign with a world saves")
	var restored := SaveManager.load_campaign(SaveManager.SLOT_DEFAULT, GameManager.config())
	not_null(restored, "campaign loads")
	if restored == null:
		return
	equal(restored.settlements.size(), 4, "settlements restored")
	equal(restored.roads.size(), 4, "roads restored")
	approx(restored.world_position.x, position.x, 0.001, "world position restored")
	equal(restored.destination_id, "brackenford", "in-progress travel restored")
	check(restored.settlement("redmoor").visited, "visited flag restored")
	equal(restored.player_gold, 640, "gold restored")

	# Loading a save must NOT rebuild the world over the top of saved state.
	var builder := WorldBuilder.new(restored, GameManager.config())
	check(not builder.build_if_needed(), "loaded world is not rebuilt from data")
	check(restored.settlement("redmoor").visited, "visited flag survives a would-be rebuild")


func _test_scene_flow() -> void:
	section("scene flow: main menu -> world map -> settlement -> back")
	SaveManager.delete_all_saves()
	var state := _fresh_campaign("Flow Test", 6789)
	var travel := TravelService.new(state, GameManager.config())

	# Arrive at greywatch (already there) and enter it via the real scene change.
	var world := await SceneManager.change_scene_and_wait("world_map")
	not_null(world, "world map scene instantiates")
	equal(SceneManager.current_key, "world_map", "SceneManager reports world_map")

	var settlement_scene := await SceneManager.change_scene_and_wait("settlement", {"settlement_id": "greywatch"})
	not_null(settlement_scene, "settlement scene instantiates")
	equal(state.current_settlement_id, "greywatch", "entering a settlement records where the party is")

	var back := await SceneManager.change_scene_and_wait("world_map", {"select_settlement_id": "greywatch"})
	not_null(back, "returned to the world map")
	equal(SceneManager.current_key, "world_map", "SceneManager reports world_map again")
	check(GameManager.campaign == state, "the same campaign survives the town round trip")
	equal(state.settlements.size(), 4, "world is intact after the round trip")

	# The debug panel must be creatable and must not need live state to report.
	var panel := DebugPanel.new()
	not_null(panel, "debug panel constructs")
	panel.setup(state, GameManager.config(), travel)
	check(panel.is_available() or not GameManager.config().get_bool("debug.enabled", true),
		"debug panel availability matches the config")
	panel.free()

	await SceneManager.change_scene_and_wait("main_menu")
	equal(SceneManager.current_key, "main_menu", "returned to the main menu")
