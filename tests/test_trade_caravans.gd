extends TestCase
## Trade caravans (D-139): the goods table, the route brain, and the traders themselves - spawn,
## walk the drawn road, arrive, trade, plan the next leg.
##
## What this suite exists to pin down:
## [br]- every good any settlement can make or want is priced in the catalogue (a good missing there
##   is a good nobody can carry);
## [br]- routes follow what towns actually trade: wants meet produces, distance is a cost, and a
##   town too far away is not a route;
## [br]- a caravan walks the same curve the map draws as its road, and this is measured, not assumed;
## [br]- arrival trades and re-plans, the same seed grows the same caravans, and a save carries them;
## [br]- traders are not hostiles: they do not chase the player and cannot be stumbled into yet.

const SEED := 5150


func run() -> void:
	await _tick()
	_test_goods_catalogue()
	_test_every_trade_good_is_priced()
	_test_route_picking()
	_test_caravans_spawn_and_walk()
	_test_caravans_stay_on_their_road()
	_test_pathing_follows_the_network()
	_test_caravans_are_slower_than_the_player()
	_test_guards_are_real_soldiers()
	_test_arrival_trades_and_replans()
	_test_meeting_a_caravan()
	_test_the_card_and_the_dialog_say_real_things()
	_test_buying_a_crate()
	_test_caravans_are_not_hostiles()
	_test_same_seed_same_caravans()
	_test_a_save_carries_a_caravan()
	GameManager.end_campaign()
	_complete()


func _campaign() -> CampaignState:
	var state := GameManager.new_campaign("Trade Test", SEED)
	state.settlements.clear()
	_add(state, "reedwood", Vector2(470.0, 600.0), ["ale", "wool"], ["iron", "grain"])
	_add(state, "wolfhallow", Vector2(920.0, 640.0), ["iron"], ["ale", "wool", "cheese"])
	_add(state, "stoneby", Vector2(1240.0, 300.0), ["grain", "cheese"], ["ale"])
	_add(state, "farhold", Vector2(3900.0, 2100.0), ["hides"], ["ale"])
	# Roads: reedwood - wolfhallow - stoneby is one chain; farhold is off the network entirely.
	state.roads.clear()
	state.roads.append({"a": "reedwood", "b": "wolfhallow", "kind": "road"})
	state.roads.append({"a": "wolfhallow", "b": "stoneby", "kind": "road"})
	return state


func _add(state: CampaignState, id: String, position: Vector2, produces: Array,
		wants: Array) -> void:
	var settlement := Settlement.new()
	settlement.id = id
	settlement.name = id.capitalize()
	settlement.type = Settlement.TYPE_TOWN
	settlement.wealth = "modest"
	settlement.population = 1200
	settlement.position = position
	for good in produces:
		settlement.produces.append(str(good))
	for good in wants:
		settlement.wants.append(str(good))
	state.settlements[id] = settlement


func _config() -> GameConfig:
	return GameConfig.load_from(GameConfig.DEFAULT_CONFIG_PATH)


func _test_goods_catalogue() -> void:
	section("the goods table")
	var goods := TradeService.goods()
	greater(goods.size(), 20, "every good the settlements trade has an entry")
	var values_ok := true
	var names_ok := true
	for id in goods.keys():
		var row: Dictionary = goods[id] as Dictionary
		if int(row.get("value", 0)) <= 0:
			values_ok = false
		if str(row.get("name", "")).is_empty() or str(row.get("category", "")).is_empty():
			names_ok = false
	check(values_ok, "and every one of them is worth something")
	check(names_ok, "and carries a name and a category")


func _test_every_trade_good_is_priced() -> void:
	section("no settlement can trade a good the catalogue cannot price")
	var goods := TradeService.goods()
	var missing := {}
	var kinds := ["village", "town", "fort", "castle"]
	for i in 24:
		var settlement := Settlement.new()
		settlement.id = "trade_%d" % i
		settlement.type = kinds[i % kinds.size()]
		settlement.owner_faction_id = "house_caldreth"
		settlement.population = 400 + i * 90
		settlement.position = Vector2(600.0 + float(i) * 310.0, 700.0 + float(i % 5) * 420.0)
		SettlementDetails.fill(settlement, SEED)
		for good in settlement.produces:
			if not goods.has(good):
				missing[good] = true
		for good in settlement.wants:
			if not goods.has(good):
				missing[good] = true
	check(missing.is_empty(), "every generated produces/wants good is in goods.json (missing: %s)"
		% ", ".join(missing.keys()))


func _test_route_picking() -> void:
	section("routes follow what towns actually trade")
	var state := _campaign()
	var reedwood := state.settlement("reedwood")
	var routes := TradeService.best_routes(reedwood, state.settlements, 3, 1500.0)
	greater(routes.size(), 0, "a town that sells gets routes")
	var ids_ok := true
	var goods_ok := true
	for route_any in routes:
		var route: Dictionary = route_any as Dictionary
		var goods: Array = route.get("goods", []) as Array
		if goods.is_empty():
			goods_ok = false
	check(goods_ok, "and every route carries something")
	var names: Array[String] = []
	for route_any in routes:
		names.append(str((route_any as Dictionary).get("id", "")))
	check(names.has("wolfhallow") or names.has("stoneby"),
		"and the town that wants ale is on the list")
	check(not names.has("farhold"), "while the town across the world is not")

	var gain := TradeService.route_gain(reedwood, state.settlement("wolfhallow"))
	check((gain.get("goods", []) as Array).size() == 2, "a trip is worth exactly what is wanted")
	greater(int(gain.get("value", 0)), 0, "and the haul is priced")


func _test_caravans_spawn_and_walk() -> void:
	section("caravans spawn and walk")
	var state := _campaign()
	var service := CaravanService.build(state, _config())
	var spawned := service.spawn_if_needed()
	greater(spawned, 0, "the roads gain caravans")
	var caravans := service.caravans()
	equal(caravans.size(), 6, "as many as the config asks for")
	var routed_ok := true
	for caravan in caravans:
		if caravan.from_settlement_id.is_empty() or caravan.to_settlement_id.is_empty():
			routed_ok = false
		if caravan.cargo.is_empty():
			routed_ok = false
	check(routed_ok, "every one of them has a town behind it and a town ahead")
	var first := caravans[0]
	var start := first.position
	var moved := service.step(2.0)
	greater(moved, 0, "an hour moves them")
	greater(first.position.distance_to(start), 1.0, "and the first one is somewhere else")


func _test_caravans_stay_on_their_road() -> void:
	section("a caravan is never off its own road")
	var state := _campaign()
	var service := CaravanService.build(state, _config())
	service.spawn_if_needed()
	service.step(3.0)
	var worst := 0.0
	for caravan in service.caravans():
		var from := state.settlement(caravan.from_settlement_id)
		var to := state.settlement(caravan.to_settlement_id)
		if from == null or to == null:
			continue
		var path := RoadPath.between(from.position, to.position)
		worst = maxf(worst, _distance_to_path(caravan.position, path))
	less(worst, 1.0, "every caravan sits on the curve the map draws (%f u off)" % worst)


## Shortest distance from a point to a polyline, in world units.
func _distance_to_path(point: Vector2, path: PackedVector2Array) -> float:
	var best := INF
	for index in range(1, path.size()):
		var a := path[index - 1]
		var b := path[index]
		var ab := b - a
		var length_squared := ab.length_squared()
		var t := 0.0 if length_squared <= 0.0 else clampf((point - a).dot(ab) / length_squared, 0.0, 1.0)
		best = minf(best, point.distance_to(a + ab * t))
	return best


func _test_pathing_follows_the_network() -> void:
	section("a caravan travels the road network, link by link")
	var state := _campaign()
	var config := _config()
	var roads := RoadNetwork.new(state, config)
	roads.normalize()
	roads.refresh_paths()
	var service := CaravanService.build(state, config, roads)
	var stops := service._path_over_links("stoneby", "reedwood")
	equal(str(stops), str(["stoneby", "wolfhallow", "reedwood"]),
		"a trip with no direct road is walked through the towns between")
	check(service._path_over_links("farhold", "reedwood").is_empty(),
		"and a town off the network is no route at all")
	service.spawn_if_needed()
	service.step(2.0)
	var legs_ok := true
	var on_curve_ok := true
	for caravan in service.caravans():
		for i in range(0, caravan.path_stops.size() - 1):
			var link := service._link_index(caravan.path_stops[i], caravan.path_stops[i + 1])
			if link < 0:
				legs_ok = false
			elif caravan.leg_index == i and caravan.path_stops.size() >= 2:
				var curve := roads.link_curve(link)
				if curve.size() >= 2:
					on_curve_ok = on_curve_ok and \
						_distance_to_path(caravan.position, curve) < 1.0
	check(legs_ok, "every leg of every route is a link the map actually draws")
	check(on_curve_ok, "and the walking is on the link's own curve, not a line beside it")


func _test_caravans_are_slower_than_the_player() -> void:
	section("never faster than the player's own walk")
	var state := _campaign()
	var config := _config()
	var service := CaravanService.build(state, config)
	service.spawn_if_needed()
	var base := config.get_float("travel.world_units_per_game_hour", 150.0)
	var caravan := service.caravans()[0]
	check(service.caravan_speed(caravan) <= base, "a caravan never beats 1x (%f)"
		% service.caravan_speed(caravan))
	check(service.caravan_speed(caravan) < base, "and it is a caravan, so it is slower")
	var empty_speed := service.caravan_speed(caravan)
	var kept := caravan.cargo.duplicate()
	caravan.cargo.clear()
	caravan.cargo.append("grain")
	caravan.cargo.append("grain")
	caravan.cargo.append("grain")
	check(service.caravan_speed(caravan) < empty_speed, "and a loaded cart is slower still")
	caravan.cargo.clear()
	for good in kept:
		caravan.cargo.append(good)


func _test_guards_are_real_soldiers() -> void:
	section("what guards a caravan is soldiers, not a number")
	var state := _campaign()
	var service := CaravanService.build(state, _config())
	service.spawn_if_needed()
	var caravan := service.caravans()[0]
	var guards := service.guards_of(caravan)
	not_null(guards, "every caravan has a guard party")
	var count := state.active_member_count(guards)
	greater(count, 0, "with soldiers in it")
	check(count >= 2 and count <= 4, "between the config's guards_min and guards_max (%d)" % count)
	var real_ok := true
	for member_id in guards.member_ids:
		if not state.soldiers.has(member_id):
			real_ok = false
	check(real_ok, "and every one of them exists in the campaign's roster")


func _test_meeting_a_caravan() -> void:
	section("meeting one on the road")
	var state := _campaign()
	var service := CaravanService.build(state, _config())
	service.spawn_if_needed()
	var caravan := service.caravans()[0]
	var found := service.nearest_meetable(caravan.position, 42.0)
	not_null(found, "standing on a caravan's road means meeting it")
	var report := service.road_report(caravan)
	check(report.length() > 20, "and it has something to say about the road")
	caravan.encounter_cooldown_until_hours = state.clock.total_hours() + 10.0
	var after := service.nearest_meetable(caravan.position, 42.0)
	check(after == null or after != caravan, "afterwards that caravan keeps its distance")


func _test_the_card_and_the_dialog_say_real_things() -> void:
	section("the card and the meeting say real things")
	var state := _campaign()
	var service := CaravanService.build(state, _config())
	service.spawn_if_needed()
	var caravan := service.caravans()[0]
	var card := CaravanHoverCard.new()
	card.show_caravan(caravan, service, state)
	var card_text := card.summary()
	check(card.visible, "the traders' card shows on hover")
	check(card_text.contains(caravan.display_name.to_upper()), "titled with the caravan's name")
	check(card_text.contains("Guards"), "carrying its guard line")
	check(card_text.contains("Carrying"), "and what is on the cart")
	card.free()

	var dialog := CaravanDialog.new()
	dialog.show_meeting(caravan, service, state)
	var dialog_text := dialog.summary()
	check(dialog.visible, "the meeting prompt opens")
	check(dialog_text.contains(caravan.display_name.to_upper()), "naming them")
	check(dialog_text.contains("guards"), "counting their spears")
	check(dialog_text.contains(str(state.settlement(caravan.to_settlement_id).name)),
		"and saying where they are bound")
	dialog.free()


func _test_buying_a_crate() -> void:
	section("a crate off the cart costs real coin")
	var state := _campaign()
	var config := _config()
	var service := CaravanService.build(state, config)
	service.spawn_if_needed()
	var caravan := service.caravans()[0]
	var gold_before := state.player_gold
	var cargo_before := caravan.cargo.size()
	var sale := service.sell_one_crate(caravan)
	check(bool(sale.get("ok", false)), "the banner can afford a crate")
	check(state.player_gold < gold_before, "and pays for it out of the campaign's own coin")
	equal(caravan.cargo.size(), cargo_before - 1, "while the cart gets lighter")

	while not caravan.cargo.is_empty():
		service.sell_one_crate(caravan)
	state.player_gold = 1
	caravan.cargo.append("horses")
	var refused := service.sell_one_crate(caravan)
	check(not bool(refused.get("ok", false)), "and a purse with one coin buys nothing")
	equal(str(refused.get("reason", "")), "not enough coin", "for the honest reason")


func _test_arrival_trades_and_replans() -> void:
	section("arrival trades and plans the next leg")
	var state := _campaign()
	var service := CaravanService.build(state, _config())
	service.spawn_if_needed()
	var first := service.caravans()[0]
	var destination := first.to_settlement_id
	var cargo := first.cargo.duplicate()
	# Enough hours to finish any leg in this small world.
	for i in 40:
		service.step(2.0)
		if first.trips > 0:
			break
	equal(first.trips, 1, "the caravan completes its trip")
	equal(first.from_settlement_id, destination, "and trades out of the town it reached")
	var reached := state.settlement(destination)
	var new_cargo_ok := true
	for good in first.cargo:
		if not reached.produces.has(good):
			new_cargo_ok = false
	check(new_cargo_ok, "buying what the town it reached actually sells (a buyer now, not a seller)")


func _test_caravans_are_not_hostiles() -> void:
	section("traders are not hostiles")
	var state := _campaign()
	var service := CaravanService.build(state, _config())
	service.spawn_if_needed()
	var caravan := service.caravans()[0]
	# Stand the player on top of the caravan: nothing hostile should happen.
	state.world_position = caravan.position
	var config := _config()
	var overworld := OverworldService.build(state, config)
	var before := caravan.position
	overworld.step(2.0)
	equal(caravan.position, before, "the overworld does not move a trader")
	var encounters := EncounterService.build(state, config)
	check(encounters.detect() == null, "and walking into one triggers no battle")


func _test_same_seed_same_caravans() -> void:
	section("one seed, the same caravans")
	var first := _campaign()
	var second := _campaign()
	var first_service := CaravanService.build(first, _config())
	var second_service := CaravanService.build(second, _config())
	first_service.spawn_if_needed()
	second_service.spawn_if_needed()
	var first_digest: Array[String] = []
	var second_digest: Array[String] = []
	for caravan in first_service.caravans():
		first_digest.append("%s|%s>%s|%s" % [caravan.id, caravan.from_settlement_id,
			caravan.to_settlement_id, str(caravan.position)])
	for caravan in second_service.caravans():
		second_digest.append("%s|%s>%s|%s" % [caravan.id, caravan.from_settlement_id,
			caravan.to_settlement_id, str(caravan.position)])
	equal(str(first_digest), str(second_digest), "same caravans, same roads, same towns")


func _test_a_save_carries_a_caravan() -> void:
	section("a save carries a caravan mid-road")
	var state := _campaign()
	var service := CaravanService.build(state, _config())
	service.spawn_if_needed()
	service.step(2.5)
	var caravan := service.caravans()[0]
	var loaded := WorldParty.from_dict(caravan.to_dict())
	equal(loaded.from_settlement_id, caravan.from_settlement_id, "the town behind it")
	equal(loaded.to_settlement_id, caravan.to_settlement_id, "the town ahead of it")
	equal(str(loaded.cargo), str(caravan.cargo), "the cargo")
	approx(loaded.route_walked, caravan.route_walked, 0.001, "the distance walked")
	equal(loaded.trips, caravan.trips, "and the trips behind it")
