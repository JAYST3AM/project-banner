extends TestCase
## Step 2 checks: the world is built from data, travel moves the party and spends
## game time, arrival works, and the debug panel is available without being able
## to corrupt anything on its own.


func run() -> void:
	await _tick()
	SaveManager.delete_all_saves()
	_test_world_builder()
	_test_travel()
	_test_march_to_open_ground()
	_test_arrival_and_enter()
	_test_speed_states()
	_test_world_survives_save_load()
	await _test_scene_flow()
	SaveManager.delete_all_saves()
	GameManager.end_campaign()
	_complete()


func _fresh_campaign(name: String, seed_value: int) -> CampaignState:
	var state := GameManager.new_campaign(name, seed_value)
	var builder := WorldBuilder.new(state, GameManager.config())
	builder.build_if_needed()
	return state


## Right click marches the party to any spot on the map, not only to a town it can enter. The order
## is a real march - it costs game hours - and it ends where it was aimed rather than at a
## settlement. This is the fix for a player clicking a hamlet and being told it is "not an
## enterable location" while the party stood still. See D-109.
func _test_march_to_open_ground() -> void:
	section("marching to open ground")
	var state := _fresh_campaign("Point Travel", 4242)
	var travel := TravelService.new(state, GameManager.config())
	var start := state.world_position
	var target := start + Vector2(240.0, 120.0)

	check(travel.set_destination_point(target), "a march to open ground is accepted")
	check(travel.is_travelling(), "and the party is travelling")
	check(travel.is_marching_to_point(), "with a point for a destination, not a settlement")
	approx(travel.distance_to(target), start.distance_to(target), 0.001, "from where it started")
	# The eta prices the ground along the line rather than at one end, so it is quoted in game
	# hours between the best road and the worst water - and it can never under-promise the distance.
	var march_pace := travel.speed_units_per_game_hour()
	var flat := travel.distance_to(target) / march_pace
	var eta := travel.hours_to_reach(target)
	check(eta >= flat / 1.4 - 0.001, "an eta is never faster than the best road would make it")
	check(eta <= flat / 0.30 + 0.001, "nor slower than the worst water")

	var guard := 0
	while travel.is_travelling() and guard < 5000:
		travel.step(1.0)
		guard += 1
	check(not travel.is_travelling(), "the march finishes")
	check(state.world_position.distance_to(target) <= travel.arrival_radius(),
		"and it ends at the spot that was ordered")

	# A place the player cannot enter can still be marched to; the settlement order refuses it,
	# which is exactly what made the map feel broken.
	var refused := ""
	for settlement in state.settlements.values():
		if not settlement.is_enterable():
			refused = settlement.id
			break
	check(refused != "", "the world has somewhere that cannot be entered")
	if refused != "":
		var place := state.settlement(refused)
		check(not travel.set_destination(refused), "the settlement order refuses to travel there")
		check(travel.set_destination_point(place.position), "but a march to the same spot is accepted")
		# Marching onto a place by a point order must leave the party *at* that place: this is what
		# lights the panel's enter button, and without it a point arrival left the party standing on
		# a town with nothing to click. See D-109.
		var settle_guard := 0
		while travel.is_travelling() and settle_guard < 5000:
			travel.step(1.0)
			settle_guard += 1
		check(state.current_settlement_id == refused, "arriving by a point order stands you in the place")
		check(place.visited, "and marks it visited")

	# An enterable town reached the same way is enterable on arrival, which is the whole point of
	# arriving at a town.
	var town_id := ""
	for settlement in state.settlements.values():
		if settlement.is_enterable():
			town_id = settlement.id
			break
	if town_id != "":
		var town := state.settlement(town_id)
		check(travel.set_destination_point(town.position), "a march aimed at a town is accepted")
		var town_guard := 0
		while travel.is_travelling() and town_guard < 5000:
			travel.step(1.0)
			town_guard += 1
		check(state.current_settlement_id == town_id, "and arriving there stands you in the town")
		check(travel.is_at_settlement(town_id), "which the panel reads as 'you are here'")

	# The destination is part of the save, so a campaign saved mid-march resumes the same march.
	check(travel.set_destination_point(state.world_position + Vector2(150.0, 0.0)),
		"a point destination is set for the save test")
	var restored := CampaignState.from_dict(state.to_dict(), GameManager.config())
	check(restored.destination_is_point, "a point destination survives a save")
	approx(restored.destination_point.distance_to(state.destination_point), 0.0, 0.001,
		"with its position intact")

	# An order that followed a road, then a march to open ground: the march must be a real straight
	# walk, not the leftover road route. The failure the owner hit - "I can't click on random
	# spots, only locations (settlements)" - happened once the road journey was *finished*: the
	# stale route ended under the party's feet, so the next march "arrived" on its first step
	# without moving.
	var marching := _fresh_campaign("Point After Road", 4243)
	var walker := TravelService.new(marching, GameManager.config())
	check(walker.set_destination("brackenford"), "a settlement order is accepted")
	var walk_guard := 0
	while walker.is_travelling() and walk_guard < 400:
		walk_guard += 1
		walker.step(1.0)
	check(not walker.is_travelling(), "the road journey finishes")
	check(walker.route.size() > 2, "having walked a built route")
	var from_here := marching.world_position
	var ordered := from_here + Vector2(300.0, 0.0)
	check(walker.set_destination_point(ordered), "then a march to open ground is accepted")
	var march_report := walker.step(0.5)
	greater(float(march_report.get("distance_travelled", 0.0)), 1.0,
		"the march actually moves the party")
	check(not bool(march_report.get("arrived", false)),
		"instead of finishing instantly at the old route's end")
	check(marching.world_position.distance_to(ordered) < from_here.distance_to(ordered) - 5.0,
		"and it moves toward the spot that was clicked")
	GameManager.end_campaign()


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
	var pace := travel.speed_units_per_game_hour()
	var flat := distance / pace
	var eta := travel.hours_to_reach(brackenford.position)
	check(eta >= flat / 1.4 - 0.001, "the eta is never faster than the best road would make it")
	check(eta <= flat / 0.30 + 0.001, "nor slower than the worst water")

	# A step covers its game hours at the ground's own pace, and no single step - however much
	# game time it is handed - outruns the configured cap.
	var factor := travel.ground_factor()
	var report := travel.step(0.1)
	check(bool(report.get("moved", false)), "step reports movement")
	var covered := distance - travel.distance_to(brackenford.position)
	var cap := config.get_float("travel.max_step_units", 24.0)
	approx(covered, minf(pace * factor * 0.1, cap), 0.5, "a step covers its hours at the ground's pace")
	var big := travel.step(10.0)
	approx(float(big.get("distance_travelled", 0.0)), cap, 0.5,
		"a single step cannot outrun the cap, whatever time it is handed")
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
	while not arrived and guard < 200:
		guard += 1
		var report := travel.step(hours / 4.0)
		arrived = bool(report.get("arrived", false))
	check(arrived, "arrival reported within a sane number of steps")
	check(travel.is_at_settlement("redmoor"), "party is at redmoor after arriving")
	equal(state.current_settlement_id, "redmoor", "current settlement updated on arrival")
	equal(state.destination_id, "", "destination cleared on arrival")
	approx(state.world_position.x, redmoor.position.x, 0.001, "party lands exactly on the settlement")
	check(redmoor.visited, "arrival marks the settlement visited")
	check(guard < 200, "arrival did not take an unreasonable number of steps")

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

	# The rate is the config's own: two real seconds buys this many game hours at normal speed.
	var config := GameManager.config()
	var per_hour := config.get_float("time.seconds_per_game_hour", 10.0)
	var normal_hours := 2.0 / per_hour
	var advanced := clock.advance_real_seconds(2.0)
	approx(advanced, normal_hours, 0.001, "normal speed: two real seconds at the configured rate")

	clock.set_speed(CampaignClock.Speed.FAST)
	var fast_multiplier := float(config.get_dict("time.speed_multipliers", {}).get("fast", 3.0))
	advanced = clock.advance_real_seconds(2.0)
	approx(advanced, normal_hours * fast_multiplier, 0.001, "fast speed: the same time, multiplied")

	clock.set_speed(CampaignClock.Speed.PAUSED)
	advanced = clock.advance_real_seconds(2.0)
	approx(advanced, 0.0, 0.001, "paused: no game time passes")
	approx(clock.hour, hour_before + normal_hours * (1.0 + fast_multiplier), 0.001,
		"only the unpaused advances applied")
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
