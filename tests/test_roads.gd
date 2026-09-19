extends TestCase
## Step 8 checks: the road network is a living thing. A link carries a tier, a settlement founded
## later links itself by a dirt road, traffic wears links up, years of neglect wear them down to
## roadless and traffic can wear them back in, the priced grid and the walking pace both read the
## tier, and the whole ledger survives a save.
##
## The world here is the authored one (the runner points world.procedural at false), so the elder
## roads between the four known settlements are the starting state and nothing about the map is
## random.
##
## The water rule (the owner: "don't let them run over water, but we could do bridges over water")
## is checked against stand-in terrains - a vertical band of water, a river when narrow and a lake
## when wide - so the shaping, the spans and the bridge walking are provable without hunting for a
## seed whose map happens to have a river in the right place.


## One vertical band of water at every height: a river when narrow, a lake when wide, dry land
## either side.
class BandTerrain extends RefCounted:
	var centre := 0.0
	var half := 0.0

	func _init(p_centre: float, p_half: float) -> void:
		centre = p_centre
		half = p_half

	func sample(point: Vector2) -> Dictionary:
		return {"height": 0.2 if absf(point.x - centre) <= half else 0.8}


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
	_test_the_pace_follows_the_drawn_road()
	_test_water_is_bridged_or_bent()
	_test_a_bridge_walks_like_a_road()
	_test_a_restamp_is_the_same_grid()
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


## The curve production shapes for a link: the terrain-aware between() with the config's own water
## settings - the same call the network, the grid, the view and the walking all make. Tests that
## want "the drawn road" want this one, never the terrain-less bend.
func _shaped(state: CampaignState, config: GameConfig, from: Vector2, to: Vector2) -> PackedVector2Array:
	return RoadPath.between(from, to, WorldChunks.build(state.campaign_seed),
		config.get_float("travel.water_height", 0.335),
		config.get_float("roads.bridge_max_span", 64.0))


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
	var path := _shaped(state, config, a.position, b.position)
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
	var path := _shaped(state, config, a.position, b.position)
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
		var path := _shaped(state, config, a.position, b.position)
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
	var path := _shaped(state, config, a.position, b.position)
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


## The pace and the eta read the line the map draws, not the priced grid: standing on the drawn road
## is the road's speed exactly, standing past its corridor is the field's, even where the grid still
## paints the surrounding block as road (D-124).
func _test_the_pace_follows_the_drawn_road() -> void:
	section("the pace follows the drawn road, not the block that prices it")
	var state := _fresh_campaign("Roads Test", 782)
	var config := GameManager.config()
	var network := RoadNetwork.new(state, config)
	var costs := TravelCosts.new()
	costs.build(state.campaign_seed, config, state.roads, state.settlements)
	var travel := TravelService.new(state, config)
	travel.costs = costs
	travel.roads = network

	var a := state.settlement("greywatch")
	var b := state.settlement("redmoor")
	var path := _shaped(state, config, a.position, b.position)
	var mid := path.size() / 2
	var here: Vector2 = path[mid]
	var across := (path[mid + 1] - path[mid - 1]).orthogonal().normalized()

	approx(travel.factor_at_point(here), network.bonus_of("road"), 0.0001,
		"on the drawn line the road's own speed answers")
	approx(travel.factor_at_point(here + across * 6.0), network.bonus_of("road"), 0.0001,
		"and inside the drawn width it still does")
	check(network.pace_radius() < network.road_radius(),
		"the pace and the eta are different questions: drawn width, and route scale")
	# The two yardsticks measured at once, forty units off the line: the walk is on open ground
	# there, while the eta - sampling a straight line that cannot see the curve underfoot - still
	# prices at the route's own scale. Shipping the eta at the pace's drawn width quoted road
	# journeys 1.5x long (D-130: 2.4 hours for a leg that walked in 1.64).
	var beside := here + across * 40.0
	state.world_position = beside
	approx(travel.ground_factor(), travel._ground_factor_at(beside), 0.0001,
		"the pace at forty units off reads the field")
	approx(travel.factor_at_point(beside), network.bonus_of("road"), 0.0001,
		"while the eta still prices it at the route scale")
	var beyond := here + across * 66.0
	approx(travel.factor_at_point(beyond), travel._ground_factor_at(beyond), 0.0001,
		"and past the shoulder even the eta reads the field")
	check(travel.factor_at_point(beyond) < network.bonus_of("road") - 0.001,
		"which is slower than the road")

	# The corner the whole change turns on: somewhere the grid paints road while the drawn line is
	# beyond its corridor. The block used to hand out its speed there; now the line decides. The
	# probe must also be outside *every* corridor, or the road itself is legitimately near.
	var leaked := false
	var leak_point := Vector2.ZERO
	for index in range(4, path.size() - 4, 2):
		var side_across := (path[index + 1] - path[index - 1]).orthogonal().normalized()
		for side in [-1.0, 1.0]:
			for step in [1.1, 1.4, 1.7, 2.0]:
				var probe: Vector2 = path[index] + side_across * (network.road_radius() * step) * side
				if network.bonus_at(probe) > 0.0:
					continue
				if costs.factor_at(probe) > network.bonus_of("road") - 0.001:
					leaked = true
					leak_point = probe
					break
			if leaked:
				break
		if leaked:
			break
	check(leaked, "the grid does paint road beyond the drawn line's corridor somewhere here")
	if leaked:
		check(travel.factor_at_point(leak_point) < network.bonus_of("road") - 0.001,
			"and the pace no longer takes its speed from that block")
	GameManager.end_campaign()


## The water rule: a shaped curve never simply runs over water. A crossing narrow enough to bridge
## is crossed, and recorded as a bridge span; anything wider is dodged by re-bending, and can never
## come out wetter than the plain bend would have been.
func _test_water_is_bridged_or_bent() -> void:
	section("a road does not run over water: it bridges a river and bends around a lake")
	var a := Vector2(200.0, 500.0)
	var b := Vector2(1100.0, 500.0)

	# A river: every candidate shape crosses it, so it must be crossed as a bridge within the limit.
	var river := BandTerrain.new(650.0, 20.0)
	var path := RoadPath.between(a, b, river)
	check(path.size() > 2, "the shaped road is a real curve")
	var spans := RoadPath.water_spans(path, river)
	greater(spans.size(), 0, "a road crossing a river is bridged")
	check(_water_inside_spans(path, river, spans), "and every unit of water lies on a recorded span")
	less(_water_run(path, river), RoadPath.BRIDGE_MAX_SPAN + 0.001, "no wider than the bridge limit")

	# The same crossing shapes the same road twice: terrain and all, the shaping is deterministic.
	approx(_path_checksum(RoadPath.between(a, b, river)), _path_checksum(path), 0.0001,
		"the same crossing shapes the same road twice")

	# A lake far wider than any bridge: every candidate is wet, so the least-wet one wins - and it
	# can never be wetter than the bare bend, nor worse than the straight crossing, the floor.
	var lake := BandTerrain.new(650.0, 300.0)
	var shaped := RoadPath.between(a, b, lake)
	var plain := RoadPath.shape(a, b, RoadPath.bend_of(a, b))
	check(_water_run(shaped, lake) <= _water_run(plain, lake) + 0.001,
		"a lake makes the road no wetter than the bare bend would be")
	check(_water_run(shaped, lake) <= _water_run(RoadPath.shape(a, b, 0.0), lake) + 0.001,
		"nor worse than the straight crossing, which is the floor")

	# Dry land draws exactly the historic bend: no terrain, no change.
	var dry := BandTerrain.new(-4000.0, 1.0)
	approx(_path_checksum(RoadPath.between(a, b, dry)), _path_checksum(plain), 0.0001,
		"and a dry land draws exactly the historic bend")


## A bridge is road ground: standing on one walks at the link's own speed, because the pace reads
## the curve and the curve is where the bridge is drawn.
func _test_a_bridge_walks_like_a_road() -> void:
	section("a bridge walks like a road")
	var state := _fresh_campaign("Roads Test", 782)
	var config := GameManager.config()
	var network := RoadNetwork.new(state, config)
	# Find a link with real horizontal reach and drop a river across its middle: the network must
	# shape that link as a bridge, whatever the hash happened to bend it into.
	var link_index := -1
	var left := Vector2.ZERO
	var right := Vector2.ZERO
	for i in state.roads.size():
		var raw: Variant = state.roads[i]
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var link := raw as Dictionary
		var a := state.settlement(str(link.get("a", "")))
		var b := state.settlement(str(link.get("b", "")))
		if a == null or b == null:
			continue
		if absf(a.position.x - b.position.x) >= 120.0:
			link_index = i
			left = a.position
			right = b.position
			break
	check(link_index >= 0, "the world has a link long enough to put a river across")
	if link_index < 0:
		GameManager.end_campaign()
		return
	network.world = BandTerrain.new((left.x + right.x) * 0.5, 20.0)
	network.refresh_paths()
	var spans := network.bridge_spans(link_index)
	greater(spans.size(), 0, "the link crosses the river by bridge")
	var curve := network.link_curve(link_index)
	var bridge: Vector2i = spans[0]
	var middle: Vector2 = curve[(int(bridge.x) + int(bridge.y)) / 2]
	approx(network.bonus_at(middle), network.bonus_of("road"), 0.0001,
		"and standing on the bridge walks at the link's own speed")
	GameManager.end_campaign()


## A link changing tier is re-stamped in place rather than rebuilt whole: the grid must be exactly
## what a full rebuild would have produced, because the owner's map used to freeze for a fifth of a
## second every time a road upgraded or decayed (D-129).
func _test_a_restamp_is_the_same_grid() -> void:
	section("a re-stamp is the same grid as a rebuild")
	var state := _fresh_campaign("Roads Test", 786)
	var config := GameManager.config()
	var network := RoadNetwork.new(state, config)
	state.roads.clear()
	var greywatch := state.settlement("greywatch")
	var brackenford := state.settlement("brackenford")
	var redmoor := state.settlement("redmoor")
	var first := {
		"a": greywatch.id, "b": brackenford.id, "kind": "road", "traffic": 0.0,
		"used_hours": state.clock.total_hours(),
	}
	var second := {
		"a": brackenford.id, "b": redmoor.id, "kind": "track", "traffic": 0.0,
		"used_hours": state.clock.total_hours(),
	}
	state.roads.append(first)
	state.roads.append(second)
	network.refresh_paths()

	var prior := TravelCosts.new()
	prior.build(state.campaign_seed, config, state.roads, state.settlements)
	var restamped := TravelCosts.new()
	restamped.build(state.campaign_seed, config, state.roads, state.settlements)

	# The first link loses a rung: re-price its ground in place.
	first["kind"] = "dirt"
	restamped.apply_tier(0)
	var rebuilt := TravelCosts.new()
	rebuilt.build(state.campaign_seed, config, state.roads, state.settlements)

	var differing := 0
	var moved := 0
	for row in TravelCosts.ROWS:
		for column in TravelCosts.COLUMNS:
			var cell := Vector2i(column, row)
			if not is_equal_approx(rebuilt.cost_of(cell), restamped.cost_of(cell)):
				differing += 1
			if not is_equal_approx(prior.cost_of(cell), restamped.cost_of(cell)):
				moved += 1
	equal(differing, 0, "the in-place re-stamp is the grid a full rebuild produces")
	greater(moved, 0, "and the tier change actually moved some ground")
	GameManager.end_campaign()


## The longest unbroken run of water under a curve, in units - the same arithmetic the shaping
## minimises, computed independently so the test is not reading the code's own answer back.
func _water_run(path: PackedVector2Array, terrain) -> float:
	var longest := 0.0
	var run := 0.0
	for i in range(1, path.size()):
		if float(terrain.sample(path[i]).get("height", 1.0)) < 0.335:
			run += path[i - 1].distance_to(path[i])
			longest = maxf(longest, run)
		else:
			run = 0.0
	return longest


## Whether every watery point of the curve sits inside one of the recorded bridge spans.
func _water_inside_spans(path: PackedVector2Array, terrain, spans: Array) -> bool:
	for i in path.size():
		if float(terrain.sample(path[i]).get("height", 1.0)) >= 0.335:
			continue
		var inside := false
		for bridge in spans:
			if i >= int(bridge.x) and i <= int(bridge.y):
				inside = true
				break
		if not inside:
			return false
	return true


## A cheap order-sensitive fingerprint of a curve, for "the same road twice" comparisons.
func _path_checksum(path: PackedVector2Array) -> float:
	var total := 0.0
	for i in path.size():
		total += path[i].x * 0.7071 + path[i].y * 0.3737 + float(i)
	return total


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
