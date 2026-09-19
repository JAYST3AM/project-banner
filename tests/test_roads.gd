extends TestCase
## Step 8 checks: the road network is a living thing. A link carries a tier, a settlement founded
## later links itself by a dirt road, traffic wears links up, years of neglect wear them down to
## roadless and traffic can wear them back in, the priced grid and the walking pace both read the
## tier, and the whole ledger survives a save.
##
## The world here is the authored one (the runner points world.procedural at false), so the elder
## roads between the four known settlements are the starting state and nothing about the map is
## random.


func run() -> void:
	await _tick()
	SaveManager.delete_all_saves()
	_test_tiers_and_normalising()
	_test_new_settlement_gets_a_dirt_road()
	_test_traffic_wears_a_road_up()
	_test_decay_takes_years()
	_test_roadless_and_revival()
	_test_grid_prices_each_tier()
	_test_travel_wears_and_walks_faster()
	_test_the_walk_follows_the_line()
	_test_roads_survive_a_save()
	SaveManager.delete_all_saves()
	GameManager.end_campaign()
	_complete()


func _fresh_campaign(campaign_name: String, seed_value: int) -> CampaignState:
	var state := GameManager.new_campaign(campaign_name, seed_value)
	var builder := WorldBuilder.new(state, GameManager.config())
	builder.build_if_needed()
	return state


## The link between two settlements, whichever way its ends are stored.
func _link_between(state: CampaignState, a: String, b: String) -> Dictionary:
	for raw in state.roads:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var link := raw as Dictionary
		var from := str(link.get("a", ""))
		var to := str(link.get("b", ""))
		if (from == a and to == b) or (from == b and to == a):
			return link
	return {}


## Drive walking over a link the honest way: short moves along the curve, each handed to the
## network exactly the way the travel service hands its own steps over.
func _walk_link(network: RoadNetwork, path: PackedVector2Array, distance: float) -> void:
	if path.size() < 2:
		return
	var walked := 0.0
	var index := 1
	var previous: Vector2 = path[0]
	while walked < distance:
		if index >= path.size():
			index = 1
			previous = path[0]
		var next: Vector2 = path[index]
		var span := previous.distance_to(next)
		network.charge_move(previous, next, span, 0.05)
		walked += span
		previous = next
		index += 1


## Somewhere the grid is plain ground and no link runs near it.
func _plain_point(state: CampaignState, network: RoadNetwork) -> Vector2:
	var candidates: Array[Vector2] = [
		state.world_position + Vector2(300.0, 260.0),
		state.world_position + Vector2(-420.0, 180.0),
		state.world_position + Vector2(200.0, -360.0),
		Vector2(640.0, 400.0),
		Vector2(160.0, 160.0),
	]
	for point in candidates:
		if network.distance_to_nearest_link(point) > 96.0:
			return point
	return candidates[candidates.size() - 1]


func _test_tiers_and_normalising() -> void:
	section("tiers and normalising")
	var state := _fresh_campaign("Roads Test", 777)
	var config := GameManager.config()
	var network := RoadNetwork.new(state, config)

	equal(network.tiers(), ["none", "dirt", "track", "road"], "the ladder, roadless to road")
	var dirt := network.bonus_of("dirt")
	greater(dirt, 1.0, "a dirt road is a little better than open ground")
	check(dirt <= 1.1, "but only a very small bonus")
	check(network.bonus_of("track") > network.bonus_of("dirt"), "a track beats dirt")
	check(network.bonus_of("road") > network.bonus_of("track"), "a road beats a track")
	approx(network.bonus_of("none"), 1.0, 0.001, "a roadless link is only the ground it runs over")

	check(state.roads.size() > 0, "the elder world starts with links")
	for raw in state.roads:
		var link := raw as Dictionary
		check(network.tiers().has(str(link.get("kind", ""))), "every link carries a known tier")
		check(float(link.get("traffic", -1.0)) >= 0.0, "and a traffic figure")
		check(float(link.get("used_hours", -1.0)) > 0.0,
			"and a last-used stamp - an old save stamps now, not the year zero")
	GameManager.end_campaign()


func _test_new_settlement_gets_a_dirt_road() -> void:
	section("a new settlement links itself")
	var state := _fresh_campaign("Roads Test", 778)
	var network := RoadNetwork.new(state, GameManager.config())
	var before := state.roads.size()

	var founded := Settlement.new()
	founded.id = "newstead"
	founded.name = "Newstead"
	var anchor := state.settlement("thornwood_hollow")
	founded.position = anchor.position + Vector2(140.0, 60.0)
	state.settlements[founded.id] = founded

	var link := network.connect_settlement(founded)
	equal(state.roads.size(), before + 1, "a road appears with the settlement")
	equal(str(link.get("kind", "")), "dirt", "as a dirt road")
	equal(str(link.get("a", "")), "newstead", "running from the new settlement")
	equal(str(link.get("b", "")), "thornwood_hollow", "to its nearest neighbour")
	approx(float(link.get("traffic", -1.0)), 0.0, 0.001, "worn by nobody yet")
	check(RoadPath.between(founded.position, anchor.position).size() > 2,
		"and the curve the map will draw exists")
	GameManager.end_campaign()


func _test_traffic_wears_a_road_up() -> void:
	section("traffic wears a road up")
	var state := _fresh_campaign("Roads Test", 779)
	var config := GameManager.config()
	var network := RoadNetwork.new(state, config)

	# A fresh dirt link of our own, so the test owns its traffic figure.
	var a := state.settlement("greywatch")
	var b := state.settlement("brackenford")
	var link := {
		"a": a.id, "b": b.id, "kind": "dirt", "traffic": 0.0, "used_hours": state.clock.total_hours(),
	}
	state.roads.append(link)
	network.refresh_paths()
	var path := RoadPath.between(a.position, b.position)
	var threshold := config.get_float("roads.upgrade_traffic.dirt", 0.0)
	greater(threshold, 0.0, "the config names what dirt needs to become a track")

	_walk_link(network, path, threshold * 0.5)
	state.clock.advance_hours(config.get_float("roads.review_hours", 6.0))
	network.review(state.clock.total_hours())
	equal(str(link.get("kind", "")), "dirt", "half the traffic does not upgrade it")

	_walk_link(network, path, threshold * 0.55)
	state.clock.advance_hours(config.get_float("roads.review_hours", 6.0))
	var changed := network.review(state.clock.total_hours())
	check(changed, "the review reports the change")
	equal(str(link.get("kind", "")), "track", "enough traffic wears it up a tier")
	check(float(link.get("traffic", 0.0)) < threshold, "the threshold is spent, the spill kept")

	var settled := str(link.get("kind", ""))
	state.clock.advance_hours(config.get_float("roads.review_hours", 6.0))
	network.review(state.clock.total_hours())
	equal(str(link.get("kind", "")), settled, "no traffic means no further climb")
	GameManager.end_campaign()


func _test_decay_takes_years() -> void:
	section("decay takes years")
	var state := _fresh_campaign("Roads Test", 780)
	var config := GameManager.config()
	var network := RoadNetwork.new(state, config)
	var days := config.get_float("roads.decay_days_per_tier", 3650.0)
	greater(days, 365.0, "a tier is not lost in a season - years of neglect per step")

	var link := _link_between(state, "greywatch", "redmoor")
	check(not link.is_empty(), "the greywatch road exists to age")
	link["kind"] = "track"
	link["used_hours"] = state.clock.total_hours()

	state.clock.advance_hours(days * 0.5 * 24.0)
	network.review(state.clock.total_hours())
	equal(str(link.get("kind", "")), "track", "half the span changes nothing")

	state.clock.advance_hours(days * 0.5 * 24.0)
	network.review(state.clock.total_hours())
	equal(str(link.get("kind", "")), "dirt", "a full span of neglect falls it one tier")

	state.clock.advance_hours(days * 24.0)
	network.review(state.clock.total_hours())
	equal(str(link.get("kind", "")), "none", "another span, and it is roadless")

	state.clock.advance_hours(days * 24.0)
	network.review(state.clock.total_hours())
	equal(str(link.get("kind", "")), "none", "and roadless is the floor")
	GameManager.end_campaign()


func _test_roadless_and_revival() -> void:
	section("roadless, and wearing one back in")
	var state := _fresh_campaign("Roads Test", 781)
	var config := GameManager.config()
	var network := RoadNetwork.new(state, config)
	var base := config.get_float("travel.world_units_per_game_hour", 150.0)

	# One link on its own, so its cells are its own: a road prices at its speed, a roadless
	# stretch prices as the ground it runs over, and enough traffic wears it back in.
	var a := state.settlement("greywatch")
	var b := state.settlement("brackenford")
	var link := {
		"a": a.id, "b": b.id, "kind": "road", "traffic": 0.0, "used_hours": state.clock.total_hours(),
	}
	state.roads.clear()
	state.roads.append(link)
	network.refresh_paths()
	var costs := TravelCosts.new()
	costs.build(state.campaign_seed, config, state.roads, state.settlements)
	var path := RoadPath.between(a.position, b.position)
	var middle: Vector2 = path[path.size() / 2]

	approx(costs.cost_of(costs.cell_at(middle)), 1.0 / (base * network.bonus_of("road")), 0.00001,
		"a road cell prices at the road's speed")
	approx(costs.factor_at(middle), network.bonus_of("road"), 0.01,
		"and the walking factor agrees with the price")

	link["kind"] = "none"
	costs.build(state.campaign_seed, config, state.roads, state.settlements)
	greater(costs.cost_of(costs.cell_at(middle)), 1.0 / (base * network.bonus_of("road")) + 0.00001,
		"a roadless stretch prices as the ground it is")

	_walk_link(network, path, config.get_float("roads.upgrade_traffic.none", 0.0) + 50.0)
	state.clock.advance_hours(config.get_float("roads.review_hours", 6.0))
	network.review(state.clock.total_hours())
	equal(str(link.get("kind", "")), "dirt", "traffic wears a roadless stretch back into a path")
	GameManager.end_campaign()


func _test_grid_prices_each_tier() -> void:
	section("the grid prices each tier")
	var state := _fresh_campaign("Roads Test", 784)
	var config := GameManager.config()
	var network := RoadNetwork.new(state, config)
	var base := config.get_float("travel.world_units_per_game_hour", 150.0)

	# Three links on their own, one per tier below road, so no two stamps share a cell.
	state.roads.clear()
	var pairs := [
		["greywatch", "redmoor", "dirt"],
		["redmoor", "brackenford", "track"],
		["brackenford", "thornwood_hollow", "road"],
	]
	for pair in pairs:
		state.roads.append({
			"a": str(pair[0]), "b": str(pair[1]), "kind": str(pair[2]),
			"traffic": 0.0, "used_hours": state.clock.total_hours(),
		})
	network.refresh_paths()
	var costs := TravelCosts.new()
	costs.build(state.campaign_seed, config, state.roads, state.settlements)

	var previous := 0.0
	for pair in pairs:
		var a := state.settlement(str(pair[0]))
		var b := state.settlement(str(pair[1]))
		var tier := str(pair[2])
		var path := RoadPath.between(a.position, b.position)
		var middle: Vector2 = path[path.size() / 2]
		var expected := 1.0 / (base * network.bonus_of(tier))
		approx(costs.cost_of(costs.cell_at(middle)), expected, 0.00001,
			"a %s cell prices at the %s's speed" % [tier, tier])
		if previous > 0.0:
			less(costs.cost_of(costs.cell_at(middle)), previous, "each tier up is cheaper ground")
		previous = costs.cost_of(costs.cell_at(middle))
	GameManager.end_campaign()


func _test_travel_wears_and_walks_faster() -> void:
	section("the travel service wears and reads it")
	var state := _fresh_campaign("Roads Test", 782)
	var config := GameManager.config()
	var network := RoadNetwork.new(state, config)
	var costs := TravelCosts.new()
	costs.build(state.campaign_seed, config, state.roads, state.settlements)
	var travel := TravelService.new(state, config)
	travel.costs = costs
	travel.roads = network

	# Standing on a road, the pace is the road's; standing on plain ground, it is the ground's.
	var a := state.settlement("greywatch")
	var b := state.settlement("redmoor")
	var path := RoadPath.between(a.position, b.position)
	var on_road: Vector2 = path[path.size() / 2]
	state.world_position = on_road
	approx(travel.ground_factor(), network.bonus_of("road"), 0.01,
		"standing on a road, the pace is the road's own price")
	var plain := _plain_point(state, network)
	state.world_position = plain
	var factor_plain := travel.ground_factor()
	check(factor_plain < network.bonus_of("road") - 0.001, "ground away from the links is slower")
	check(network.on_road(on_road), "a link's midpoint reads as on-road")
	check(not network.on_road(plain), "and ground away from every link does not")
	contains(network.link_label(network.nearest_link(on_road)), "Greywatch",
		"and the log can name the link the party is standing on")

	# The same slice of game time covers more road than plain ground, in the ratio of the factors.
	state.world_position = on_road
	var factor_road := travel.ground_factor()
	travel.set_destination_point(on_road + Vector2(500.0, 0.0))
	var first := travel.step(0.05)
	travel.clear_destination()
	var moved_road := float(first.get("distance_travelled", 0.0))
	state.world_position = plain
	travel.set_destination_point(plain + Vector2(500.0, 0.0))
	var second := travel.step(0.05)
	travel.clear_destination()
	var moved_plain := float(second.get("distance_travelled", 0.0))
	greater(moved_road, moved_plain, "a slice covers more road than ground")
	approx(moved_road / moved_plain, factor_road / factor_plain, 0.05,
		"in the ratio of the ground's own factors")

	# Walking a settlement route lays wear on the link it follows.
	state.world_position = path[5]
	var link := _link_between(state, "greywatch", "redmoor")
	var worn_before := float(link.get("traffic", 0.0))
	check(travel.set_destination("redmoor"), "a route to the next town is accepted")
	for i in 12:
		travel.step(0.1)
	check(float(link.get("traffic", 0.0)) > worn_before, "walking the link wears it")
	travel.clear_destination()
	GameManager.end_campaign()


## The owner, watching a journey: "I see my pawn moving in a straight line... I think the game
## thinks that block is road." It did - the grid prices blocks, the drawing is a line, and the walk
## split the difference. A route that runs along a road is now spliced onto that road's own curve,
## so the marker walks the line the map draws. This section is the proof, in the same units the
## travel log reports: the distance from the walking party to the nearest link's curve.
func _test_the_walk_follows_the_line() -> void:
	section("the walk follows the drawn line")
	var state := _fresh_campaign("Roads Test", 785)
	var config := GameManager.config()
	var network := RoadNetwork.new(state, config)
	var costs := TravelCosts.new()
	costs.build(state.campaign_seed, config, state.roads, state.settlements)
	var travel := TravelService.new(state, config)
	travel.costs = costs
	travel.roads = network

	check(travel.set_destination("redmoor"), "a route to the next town is accepted")
	travel.build_route(state.settlement("redmoor"))
	var once := travel.route.duplicate()
	travel.build_route(state.settlement("redmoor"))
	equal(travel.route, once, "and the same order builds the same route twice")

	var worst := 0.0
	var slices := 0
	var guard := 0
	while travel.is_travelling() and guard < 500:
		guard += 1
		travel.step(0.1)
		worst = maxf(worst, network.distance_to_nearest_link(state.world_position))
		slices += 1
	check(not travel.is_travelling(), "the journey finishes")
	greater(float(slices), 10.0, "it was a real journey")
	less(worst, 12.0, "and the walk never wanders more than a dozen units off a line")
	check(network.on_road(state.world_position), "the walk ends standing on the road to redmoor")
	approx(state.world_position.distance_to(state.settlement("redmoor").position), 0.0, 0.001,
		"and lands exactly on the settlement, as before")
	GameManager.end_campaign()


func _test_roads_survive_a_save() -> void:
	section("roads survive a save")
	var state := _fresh_campaign("Roads Test", 783)
	RoadNetwork.new(state, GameManager.config())
	var link := _link_between(state, "greywatch", "redmoor")
	link["kind"] = "track"
	link["traffic"] = 123.5
	link["used_hours"] = 456.25

	var restored := CampaignState.from_dict(state.to_dict(), GameManager.config())
	var back := _link_between(restored, "greywatch", "redmoor")
	equal(str(back.get("kind", "")), "track", "the tier is in the save")
	approx(float(back.get("traffic", 0.0)), 123.5, 0.001, "so is the traffic")
	approx(float(back.get("used_hours", 0.0)), 456.25, 0.001, "and when it was last walked")

	# And a load brings the network up without touching what the save carried.
	var reloaded := RoadNetwork.new(restored, GameManager.config())
	approx(float(back.get("traffic", 0.0)), 123.5, 0.001, "the network leaves the ledger alone")
	equal(str(back.get("kind", "")), "track", "and the tier")
	check(reloaded.distance_to_nearest_link(restored.settlement("greywatch").position) < 200.0,
		"with the curves rebuilt from the links")
	GameManager.end_campaign()
