class_name CaravanService
extends RefCounted
## Trade caravans (D-139): the roads' own life. Each caravan is a [WorldParty] of kind
## [code]caravan[/code] that buys what one town sells and walks it to a town that wants it - along
## the road network's own links, the exact curves the map draws, at a pace the owner set the rules
## for: never faster than the player's own walk, slower for being a caravan, and slower again for
## what it carries.
##
## The foundations only: no prices that move, no money that changes hands yet, and no way for the
## player to meet one. What exists is the loop (choose a route, walk the links, arrive, trade,
## choose again), and a log that says what every caravan did and why - behaviour is only debuggable
## if it is written down.
##
## D-140 gave it money and classes. A caravan belongs to a noble house, a chartered guild or is an
## independent with one wagon and no illusions; each class starts with its own purse (nobles hold
## the land, so theirs is deep), BUYS the load it carries out of that purse at the origin, and is
## paid for it at the far end. Spending power is therefore real: a noble fills a cart with jewellery
## and horses, an independent scrapes together two crates of ale. A caravan with nothing to sell
## anywhere walks home again rather than standing in a field forever.
##
## Deterministic like everything else: routes come from named RNG streams, so the same seed grows
## the same caravans and a save needs only their positions and legs (both in [WorldParty]).

const TRADERS_PATH := "res://data/config/traders.json"

var state: CampaignState = null
var config: GameConfig = null
## The road network, for its link curves: a caravan walks the drawn road, never a fresh line that
## happens to point the right way.
var roads: RoadNetwork = null
## The unit catalogue guards are rolled from. Loaded on first use.
var units: UnitCatalog = null
## The trader classes (D-140): id, label, purse range, guards, cart size, and where its caravans
## start. Loaded once from data/config/traders.json.
var classes: Array = []

## The current leg's curve, keyed by caravan id: {"key": "from>to", "curve": PackedVector2Array}
var _paths: Dictionary = {}
var _last_digest_day := -1


static func build(p_state: CampaignState, p_config: GameConfig, p_roads: RoadNetwork = null) -> CaravanService:
	var service := CaravanService.new()
	service.state = p_state
	service.config = p_config
	service.roads = p_roads
	service.classes = service._load_classes()
	service._migrate_existing()
	return service


## The trader classes, read once. An unreadable file means no caravans rather than invented ones.
func _load_classes() -> Array:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(TRADERS_PATH))
	if typeof(parsed) != TYPE_DICTIONARY:
		DebugLogger.warn("trade: could not read %s, so no caravans are classed" % TRADERS_PATH, "Trade")
		return []
	return ((parsed as Dictionary).get("classes", []) as Array).duplicate()


## A save from before the classes (or a hand-made caravan) becomes an independent with a small
## purse - the honest guess, and better than a caravan that cannot buy anything.
func _migrate_existing() -> void:
	for caravan in caravans():
		if not caravan.trader_class.is_empty():
			continue
		caravan.trader_class = "independent"
		if caravan.cash <= 0:
			caravan.cash = 60
		if caravan.home_settlement_id.is_empty():
			caravan.home_settlement_id = caravan.from_settlement_id


func _class_by_id(id: String) -> Dictionary:
	for entry in classes:
		var row: Dictionary = entry as Dictionary
		if str(row.get("id", "")) == id:
			return row
	return {}


## A caravan's class in the player's words ("Noble house", "Trade guild", "Independent trader").
func class_label(caravan: WorldParty) -> String:
	var row := _class_by_id(caravan.trader_class)
	if row.is_empty():
		return "Trader"
	return str(row.get("label", caravan.trader_class))


## Every caravan currently on the road.
func caravans() -> Array[WorldParty]:
	var found: Array[WorldParty] = []
	for key in state.parties.keys():
		var world_party := state.parties[key] as WorldParty
		if world_party != null and world_party.kind == Party.KIND_CARAVAN:
			found.append(world_party)
	return found


## The pace a caravan travels at. The owner's rules: never faster than the player's own walk (1x),
## always a caravan's discount on top of that, and every good in the cart costs a little more.
func caravan_speed(caravan: WorldParty) -> float:
	var base := config.get_float("travel.world_units_per_game_hour", 150.0)
	var factor := minf(config.get_float("trade.speed_multiplier", 0.75), 1.0)
	var per_good := config.get_float("trade.cargo_speed_penalty_per_good", 0.06)
	var load := 1.0 - per_good * float(caravan.cargo.size())
	var speed := base * clampf(factor * maxf(load, 0.4), 0.05, 1.0)
	return minf(speed, base)


## How long the caravan's current leg should take, in game hours (0 when it has no leg).
func leg_hours(caravan: WorldParty) -> float:
	if caravan.path_stops.size() < 2 or caravan.leg_index + 1 >= caravan.path_stops.size():
		return 0.0
	var from := state.settlement(caravan.path_stops[caravan.leg_index])
	var to := state.settlement(caravan.path_stops[caravan.leg_index + 1])
	if from == null or to == null:
		return 0.0
	var speed := caravan_speed(caravan)
	if speed <= 0.0:
		return 0.0
	return _path_length(_leg_curve(caravan, from, to)) / speed


## Make sure the roads carry as many caravans as the classes ask for. Called once per map entry; a
## save that already holds caravans keeps them (spawn only tops up what is missing).
func spawn_if_needed() -> int:
	if classes.is_empty():
		return 0
	var wanted := 0
	for entry in classes:
		wanted += int((entry as Dictionary).get("count", 0))
	var existing := caravans().size()
	if existing >= wanted:
		return 0
	var spawned := 0
	var used_starts := {}
	var index := existing
	for entry in classes:
		var class_def: Dictionary = entry as Dictionary
		var count := int(class_def.get("count", 0))
		for slot in count:
			if index >= wanted:
				break
			var caravan := _spawn_one(class_def, index, used_starts)
			index += 1
			if caravan == null:
				continue
			state.parties[caravan.id] = caravan
			_hire_guards(caravan)
			_plan(caravan)
			spawned += 1
	var summary := []
	for entry in classes:
		var class_def: Dictionary = entry as Dictionary
		summary.append("%d %s" % [int(class_def.get("count", 0)), str(class_def.get("id", "?"))])
	DebugLogger.info("trade: %d caravans on the road (%s) - %d wanted" % [
		caravans().size(), ", ".join(summary), wanted], "Trade")
	return spawned


## One caravan of one class: a home it plausibly belongs to, a name that says who it is, a purse,
## and a cart suited to both. Null when nowhere fits (the warning says which class came up short).
func _spawn_one(class_def: Dictionary, index: int, used_starts: Dictionary) -> WorldParty:
	var class_id := str(class_def.get("id", "independent"))
	var generator := state.rng.stream("trade:spawn:%s:%d" % [class_id, index])
	var starts := _homes_for(class_def, used_starts)
	if starts.is_empty():
		starts = _starting_settlements()
	if starts.is_empty():
		DebugLogger.warn("trade: no settlement can start a %s caravan" % class_id, "Trade")
		return null
	var start: Settlement = starts[generator.randi_range(0, starts.size() - 1)]
	used_starts[start.id] = true

	var caravan := WorldParty.new()
	caravan.id = "caravan_%s_%02d" % [class_id, index]
	caravan.party_id = caravan.id
	caravan.kind = Party.KIND_CARAVAN
	caravan.behaviour = WorldParty.BEHAVIOUR_TRADE
	caravan.trader_class = class_id
	caravan.cash = generator.randi_range(
		int(class_def.get("cash_min", 25)), int(class_def.get("cash_max", 80)))
	caravan.home_settlement_id = start.id
	caravan.position = start.position
	caravan.home_position = start.position
	caravan.destination = start.position
	caravan.from_settlement_id = start.id
	caravan.display_name = _name_for_class(class_def, caravan, start, index)
	DebugLogger.info("trade: %s takes the road at %s with %d coin (%s)" % [
		caravan.display_name, start.name, caravan.cash, str(class_def.get("label", class_id))],
		"Trade")
	return caravan


## Where a class starts: a house wants a town its family is a name in; a guild wants a guild hall;
## anyone else takes a town that can trade. Only towns that can actually trade qualify for ANY of
## them - a caravan born in a dead end would idle on its first step.
func _homes_for(class_def: Dictionary, used_starts: Dictionary) -> Array[Settlement]:
	var can_trade := {}
	for town in _starting_settlements():
		can_trade[town.id] = true
	var homes: Array[Settlement] = []
	var wants := str(class_def.get("homes", "any"))
	for key in state.settlements.keys():
		var town := state.settlements[key] as Settlement
		if town == null or used_starts.has(town.id) or not can_trade.has(town.id):
			continue
		match wants:
			"families":
				if not town.families.is_empty():
					homes.append(town)
			"guild_hall":
				if _has_building(town, "guild_hall"):
					homes.append(town)
			_:
				homes.append(town)
	return homes


func _has_building(town: Settlement, building_id: String) -> bool:
	for entry in town.buildings:
		if str((entry as Dictionary).get("id", "")) == building_id:
			return true
	return false


## The caravan's name, in the class's own idiom: a house, a guild, or a person with one wagon.
func _name_for_class(class_def: Dictionary, caravan: WorldParty, start: Settlement,
		index: int) -> String:
	var class_id := str(class_def.get("id", "independent"))
	if class_id == "noble":
		var house := "the House"
		if not start.families.is_empty():
			var owner: Dictionary = start.families[0] as Dictionary
			house = str(owner.get("name", "Unknown"))
			# The family rolls already speak in display names ("House Caldreth") - never say it twice.
			if not house.begins_with("House "):
				house = "House %s" % house
		caravan.house = house.trim_prefix("House ")
		return "%s caravan" % house
	if class_id == "guild":
		var names: Array = class_def.get("names", []) as Array
		var pick := index % maxi(names.size(), 1)
		var guild := str(names[pick]) if not names.is_empty() else "The Guild"
		return "%s caravan" % guild
	var generator := state.rng.stream("trade:traders:%s" % caravan.id)
	var people := NameGenerator.load_from(state.rng)
	var person: Dictionary = people.name_for(generator.randi_range(0, 99999), {})
	var who := "%s %s" % [str(person.get("first_name", "A")), str(person.get("surname", "Trader"))]
	return "%s's wagon" % who


## Advance every caravan by the hours the clock just moved, then say what the day looked like.
func step(game_hours: float) -> int:
	if game_hours <= 0.0:
		return 0
	var moved := 0
	for caravan in caravans():
		if _step_caravan(caravan, game_hours):
			moved += 1
	_digest_if_new_day()
	return moved


## ---------- the loop -----------------------------------------------------

func _step_caravan(caravan: WorldParty, game_hours: float) -> bool:
	if caravan.path_stops.size() < 2:
		_plan(caravan)
		if caravan.path_stops.size() < 2:
			return false
	if caravan.leg_index + 1 >= caravan.path_stops.size():
		_arrive(caravan)
		return true
	var from := state.settlement(caravan.path_stops[caravan.leg_index])
	var to := state.settlement(caravan.path_stops[caravan.leg_index + 1])
	if from == null or to == null:
		caravan.path_stops.clear()
		return false
	var curve := _leg_curve(caravan, from, to)
	if curve.size() < 2:
		caravan.path_stops.clear()
		return false
	var total := _path_length(curve)
	caravan.route_walked += caravan_speed(caravan) * game_hours
	if caravan.route_walked >= total:
		caravan.position = curve[curve.size() - 1]
		caravan.route_walked = 0.0
		caravan.leg_index += 1
		if caravan.leg_index + 1 >= caravan.path_stops.size():
			_arrive(caravan)
		else:
			DebugLogger.debug("trade: %s passes through %s" % [caravan.display_name, to.name],
				"Trade")
		return true
	caravan.position = _point_at(curve, caravan.route_walked)
	caravan.destination = curve[curve.size() - 1]
	return true


## Choose where this caravan goes next: a buyer its town can reach by road, with a load its own
## purse can pay for. A caravan whose town has no buyer - or whose purse cannot cover a single crate
## - walks home and tries again there; only a caravan already home complains, and only once.
func _plan(caravan: WorldParty) -> void:
	caravan.path_stops.clear()
	var from := state.settlement(caravan.from_settlement_id)
	if from == null:
		_warn_idle(caravan, "the town it was trading from no longer exists")
		return
	var max_units := config.get_float("trade.max_route_units", 1500.0)
	var routes := TradeService.best_routes(from, state.settlements, 5, max_units)
	var reachable: Array = []
	for route_any in routes:
		var route: Dictionary = route_any as Dictionary
		if not _path_over_links(from.id, str(route.get("id", ""))).is_empty():
			reachable.append(route)
	if reachable.is_empty():
		_leave_for_home(caravan, from, "no road to a buyer within %d u" % int(max_units))
		return
	# The best road most of the time, the second or third often enough that two caravans out of the
	# same town do not always take the same road.
	var generator := state.rng.stream("trade:route:%s:%d" % [caravan.id, caravan.trips])
	var roll := generator.randf()
	var index := 0
	if roll >= 0.6:
		index = 1
	if roll >= 0.85:
		index = 2
	index = mini(index, reachable.size() - 1)

	# Buy the load out of the purse, best goods first, capped by the class's cart. A route beyond
	# the purse is skipped for the next one - a poor caravan still trades, just small.
	var class_def := _class_by_id(caravan.trader_class)
	var units_max := int(class_def.get("units_max", 2))
	var chosen: Dictionary = {}
	var load: Dictionary = {}
	for offset in reachable.size():
		var candidate: Dictionary = reachable[(index + offset) % reachable.size()] as Dictionary
		var buyer := state.settlement(str(candidate.get("id", "")))
		if buyer == null:
			continue
		var bought := TradeService.buy_load(from, buyer, caravan.cash, units_max)
		if not (bought.get("goods", []) as Array).is_empty():
			chosen = candidate
			load = bought
			break
	if chosen.is_empty():
		_leave_for_home(caravan, from, "nothing its purse of %d coin can buy" % caravan.cash)
		return

	var stops := _path_over_links(from.id, str(chosen.get("id", "")))
	if stops.size() < 2:
		_warn_idle(caravan, "the road to its buyer vanished")
		return
	caravan.path_stops.clear()
	for stop in stops:
		caravan.path_stops.append(str(stop))
	caravan.leg_index = 0
	caravan.route_walked = 0.0
	caravan.to_settlement_id = str(chosen.get("id", ""))
	caravan.cargo.clear()
	for good_any in (load.get("goods", []) as Array):
		caravan.cargo.append(str(good_any))
	caravan.cash -= int(load.get("cost", 0))
	caravan.idle_warned = false
	var guard_party := state.caravan_parties.get(caravan.id, null) as Party
	if guard_party != null:
		guard_party.display_name = caravan.display_name

	var to := state.settlement(caravan.to_settlement_id)
	var speed := caravan_speed(caravan)
	var percent := 100.0 * speed / maxf(1.0, config.get_float("travel.world_units_per_game_hour", 150.0))
	var via := ""
	if caravan.path_stops.size() > 2:
		var mids: Array[String] = []
		for i in range(1, caravan.path_stops.size() - 1):
			var mid := state.settlement(caravan.path_stops[i])
			mids.append(mid.name if mid != null else "?")
		via = " via %s" % ", ".join(mids)
	DebugLogger.info("trade: %s departs for %s%s carrying %s, paid %d, purse %d, at %d u/h (%.0f%% of a walker's pace), ~%.1f h out" % [
		caravan.display_name, to.name if to != null else "?", via,
		TradeService.describe_cargo(caravan.cargo, int(chosen.get("value", 0))),
		int(load.get("cost", 0)), caravan.cash,
		int(round(speed)), percent, leg_hours(caravan)], "Trade")


## No trade here: a caravan with nothing to sell does not stand in a field. It walks home and tries
## again there; if it IS home, it walks to the nearest town where its purse can actually buy, and
## only gives up (once, loudly) when there is no town anywhere its coin is enough.
func _leave_for_home(caravan: WorldParty, from: Settlement, reason: String) -> void:
	var destination := state.settlement(caravan.home_settlement_id)
	var going := "heads home to %s" % (destination.name if destination != null else "?")
	if destination == null or destination.id == from.id:
		destination = _town_worth_trying(caravan, from)
		going = "moves on to %s" % (destination.name if destination != null else "?")
	if destination == null:
		_warn_idle(caravan, reason)
		return
	var stops := _path_over_links(from.id, destination.id)
	if stops.size() < 2:
		_warn_idle(caravan, "%s, and no road out of %s" % [reason, from.name])
		return
	caravan.path_stops.clear()
	for stop in stops:
		caravan.path_stops.append(str(stop))
	caravan.leg_index = 0
	caravan.route_walked = 0.0
	caravan.to_settlement_id = destination.id
	caravan.cargo.clear()
	caravan.idle_warned = false
	DebugLogger.info("trade: %s %s (%s)" % [caravan.display_name, going, reason], "Trade")


## The nearest town where this caravan could actually buy a load - the difference between a trader
## with an empty wagon and a trader with an empty wagon and nowhere to go. Nearest first, by road
## distance; the first few towns are enough to find a market.
func _town_worth_trying(caravan: WorldParty, from: Settlement) -> Settlement:
	var max_units := config.get_float("trade.max_route_units", 1500.0)
	var class_def := _class_by_id(caravan.trader_class)
	var units_max := int(class_def.get("units_max", 2))
	var candidates: Array[Dictionary] = []
	for key in state.settlements.keys():
		var town := state.settlements[key] as Settlement
		if town == null or town.id == from.id:
			continue
		if _path_over_links(from.id, town.id).is_empty():
			continue
		candidates.append({"town": town, "distance": from.position.distance_to(town.position)})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["distance"]) < float(b["distance"]))
	for entry in candidates.slice(0, 6):
		var town: Settlement = entry["town"] as Settlement
		for route_any in TradeService.best_routes(town, state.settlements, 3, max_units):
			var route: Dictionary = route_any as Dictionary
			var buyer := state.settlement(str(route.get("id", "")))
			if buyer == null or _path_over_links(town.id, buyer.id).is_empty():
				continue
			var bought := TradeService.buy_load(town, buyer, caravan.cash, units_max)
			if not (bought.get("goods", []) as Array).is_empty():
				return town
	return null


## Arrived: the load is sold at what this town will pay, the purse takes the coin, and the caravan
## becomes a buyer here - the next leg is bought with the money this one earned (D-140).
func _arrive(caravan: WorldParty) -> void:
	var to := state.settlement(caravan.to_settlement_id)
	if to == null:
		caravan.path_stops.clear()
		return
	var sold := TradeService.sale_value(caravan.cargo, to)
	caravan.cash += sold
	caravan.trips += 1
	if caravan.cargo.is_empty():
		DebugLogger.info("trade: %s reached %s (trip %d) with an empty cart, purse %d" % [
			caravan.display_name, to.name, caravan.trips, caravan.cash], "Trade")
	else:
		DebugLogger.info("trade: %s reached %s (trip %d): sold %s for %d coin - purse %d" % [
			caravan.display_name, to.name, caravan.trips,
			TradeService.describe_cargo(caravan.cargo, sold), sold, caravan.cash], "Trade")
	caravan.from_settlement_id = to.id
	caravan.to_settlement_id = ""
	caravan.cargo.clear()
	caravan.path_stops.clear()
	_plan(caravan)


## A caravan with nothing to do says so once per stuck episode, not once per step.
func _warn_idle(caravan: WorldParty, reason: String) -> void:
	if caravan.idle_warned:
		return
	caravan.idle_warned = true
	DebugLogger.warn("trade: %s is idle at %s - %s" % [
		caravan.display_name, caravan.from_settlement_id, reason], "Trade")


## One line per game day, so a play session's log says what the roads were doing.
func _digest_if_new_day() -> void:
	if state.clock == null:
		return
	var day := state.clock.day
	if day == _last_digest_day:
		return
	_last_digest_day = day
	# Everything is read off the caravans themselves, not off counters living in this service: a map
	# re-entry builds a new service, and a digest that forgets this morning's deliveries is worse
	# than no digest (D-140 - the first live log said "0 arrivals so far" while two had just sold).
	var moving := 0
	var idle := 0
	var deliveries := 0
	var purse := 0
	var richest := 0
	for caravan in caravans():
		if caravan.path_stops.size() >= 2:
			moving += 1
		else:
			idle += 1
		deliveries += caravan.trips
		purse += caravan.cash
		richest = maxi(richest, caravan.cash)
	DebugLogger.info("trade digest: day %d - %d caravans, %d on the road, %d idle, %d deliveries so far, %d coin in purses (richest %d)" % [
		day, caravans().size(), moving, idle, deliveries, purse, richest], "Trade")


## ---------- roads --------------------------------------------------------

## The stops from one town to another over the road network: [from, ...towns..., to], or empty when
## no chain of links reaches. Breadth-first over the links, so a caravan only ever walks roads that
## are actually drawn on the map.
func _path_over_links(from_id: String, to_id: String) -> Array[String]:
	var empty: Array[String] = []
	if from_id == to_id or from_id.is_empty() or to_id.is_empty():
		return empty
	var neighbours := _neighbours()
	var came_from := {from_id: ""}
	var queue: Array[String] = [from_id]
	var guard := 0
	while not queue.is_empty() and guard < 4096:
		guard += 1
		var here: String = queue.pop_front()
		if here == to_id:
			return _reconstruct(came_from, from_id, to_id)
		for next_any in (neighbours.get(here, []) as Array):
			var next := str(next_any)
			if came_from.has(next):
				continue
			came_from[next] = here
			queue.append(next)
	return empty


func _reconstruct(came_from: Dictionary, from_id: String, to_id: String) -> Array[String]:
	var stops: Array[String] = [to_id]
	var here := to_id
	while here != from_id:
		here = str(came_from.get(here, ""))
		if here.is_empty():
			var broken: Array[String] = []
			return broken
		stops.append(here)
	stops.reverse()
	return stops


## id -> [neighbour ids], from the campaign's own links. Rebuilt per call: a plan happens a few
## times an hour at most, and a stale cache across a growing road network is the worse trade.
func _neighbours() -> Dictionary:
	var neighbours := {}
	for raw in state.roads:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var link := raw as Dictionary
		if str(link.get("kind", "road")) == "none":
			continue
		var a := str(link.get("a", ""))
		var b := str(link.get("b", ""))
		if a.is_empty() or b.is_empty():
			continue
		(neighbours.get_or_add(a, []) as Array).append(b)
		(neighbours.get_or_add(b, []) as Array).append(a)
	return neighbours


## The curve for the current leg: the network's own link curve - the exact line the map draws - or
## a fresh [method RoadPath.between] when the network does not know the link.
func _leg_curve(caravan: WorldParty, from: Settlement, to: Settlement) -> PackedVector2Array:
	var key := "%s>%s" % [from.id, to.id]
	var held: Dictionary = _paths.get(caravan.id, {}) as Dictionary
	if str(held.get("key", "")) == key:
		return held.get("curve", PackedVector2Array()) as PackedVector2Array
	var curve := PackedVector2Array()
	var index := _link_index(from.id, to.id)
	if roads != null and index >= 0:
		curve = roads.link_curve(index)
	if curve.size() < 2:
		curve = RoadPath.between(from.position, to.position)
	_paths[caravan.id] = {"key": key, "curve": curve}
	return curve


## The index of the link between two settlements in [member CampaignState.roads], or -1.
func _link_index(a_id: String, b_id: String) -> int:
	for index in state.roads.size():
		var link: Dictionary = state.roads[index] as Dictionary
		if str(link.get("kind", "road")) == "none":
			continue
		var a := str(link.get("a", ""))
		var b := str(link.get("b", ""))
		if (a == a_id and b == b_id) or (a == b_id and b == a_id):
			return index
	return -1


static func _path_length(path: PackedVector2Array) -> float:
	var total := 0.0
	for index in range(1, path.size()):
		total += path[index - 1].distance_to(path[index])
	return total


## The point [param distance] along the polyline, clamped to the end.
static func _point_at(path: PackedVector2Array, distance: float) -> Vector2:
	var left := distance
	for index in range(1, path.size()):
		var segment := path[index - 1].distance_to(path[index])
		if left <= segment:
			if segment <= 0.0:
				return path[index]
			return path[index - 1].lerp(path[index], left / segment)
		left -= segment
	return path[path.size() - 1]


## ---------- guards, trade and meetings -----------------------------------

## Real soldiers behind the name, so a tooltip's "3 spears" is a fact and a later robbery is a fight
## rather than a dice roll. Deterministic per caravan; the first guard carries the spear.
func _hire_guards(caravan: WorldParty) -> void:
	var generator := state.rng.stream("trade:guards:%s" % caravan.id)
	var class_def := _class_by_id(caravan.trader_class)
	var count := generator.randi_range(
		int(class_def.get("guards_min", config.get_int("trade.guards_min", 2))),
		int(class_def.get("guards_max", config.get_int("trade.guards_max", 4))))
	var catalog: UnitCatalog = units if units != null else UnitCatalog.load_from()
	if catalog == null:
		return
	var party := Party.new()
	party.id = caravan.id
	party.kind = Party.KIND_CARAVAN
	party.display_name = caravan.display_name
	party.faction_id = "traders"
	var taken := _taken_names()
	var names := NameGenerator.load_from(state.rng)
	for slot in count:
		var unit_id := "spearman" if slot == 0 else "peasant_recruit"
		var definition := catalog.get_definition(unit_id)
		if definition == null:
			continue
		var soldier := Soldier.new()
		var index := int(absf(hash("%s:%d" % [caravan.id, slot]))) % 100000
		var rolled := names.name_for(index, taken)
		soldier.first_name = str(rolled.get("first_name", "Unnamed"))
		soldier.surname = str(rolled.get("surname", ""))
		soldier.unit_type_id = unit_id
		soldier.faction_id = "traders"
		soldier.age = names.value_for(index, "age", 20, 48)
		soldier.level = 1
		soldier.max_hp = definition.max_hp_at(1, config)
		soldier.hp = soldier.max_hp
		soldier.morale = names.value_for(index, "morale", 45, 70)
		soldier.loyalty = names.value_for(index, "loyalty", 40, 70)
		state.register_soldier(soldier)
		party.add_member(soldier.id)
		state.soldiers[soldier.id] = soldier
		taken["%s %s" % [soldier.first_name, soldier.surname]] = true
	state.caravan_parties[party.id] = party


## The guard party of a caravan, or null for a caravan that travels alone.
func guards_of(caravan: WorldParty) -> Party:
	return state.caravan_parties.get(caravan.id, null) as Party


## Sell one crate off a caravan's cart to the player, at the catalogue's value plus the trader's
## margin. The player's coin is the only money in the game this foundation moves; everything else
## still trades in cargo.
func sell_one_crate(caravan: WorldParty) -> Dictionary:
	if caravan == null or caravan.cargo.is_empty():
		return {"ok": false, "reason": "nothing on the cart"}
	var good := caravan.cargo[0]
	var markup := config.get_float("trade.markup", 1.2)
	var price := int(ceil(float(TradeService.value_of(good)) * markup))
	if state.player_gold < price:
		return {"ok": false, "reason": "not enough coin", "good": good, "price": price}
	state.player_gold -= price
	caravan.cargo.remove_at(0)
	DebugLogger.info("trade: sold a crate of %s to the banner for %d coin (%s caravan bound for %s)" % [
		TradeService.name_of(good).to_lower(), price, caravan.display_name,
		caravan.to_settlement_id], "Trade")
	return {"ok": true, "good": good, "price": price}


## What the caravan will tell anyone who asks: where it is bound, what it carries, and what the
## town ahead of it sells - all read from the simulation, so the answer is always true.
func road_report(caravan: WorldParty) -> String:
	var to := state.settlement(caravan.to_settlement_id)
	if to == null:
		return "Between roads, deciding where the next coin is."
	var cargo := TradeService.describe_cargo(caravan.cargo, _cargo_value(caravan))
	var line := "Bound for %s with %s." % [to.name, cargo]
	if caravan.path_stops.size() > 2:
		var mids: Array[String] = []
		for i in range(1, caravan.path_stops.size() - 1):
			var mid := state.settlement(caravan.path_stops[i])
			mids.append(mid.name if mid != null else "?")
		line += " The road runs through %s." % ", ".join(mids)
	if not to.produces.is_empty():
		var goods: Array[String] = []
		for good in to.produces:
			goods.append(TradeService.name_of(good).to_lower())
		line += " They load %s there, and someone will want it." % ", ".join(goods)
	return line


func _cargo_value(caravan: WorldParty) -> int:
	var value := 0
	for good in caravan.cargo:
		value += TradeService.value_of(good)
	return value


## The nearest caravan the player could meet: within [param radius], off cooldown, and not already
## being talked to. What "meeting one" means lives with the caller.
func nearest_meetable(from_position: Vector2, radius: float) -> WorldParty:
	var now := 0.0
	if state.clock != null:
		now = state.clock.total_hours()
	var best: WorldParty = null
	var best_distance := radius
	for caravan in caravans():
		if now < caravan.encounter_cooldown_until_hours:
			continue
		var distance := from_position.distance_to(caravan.position)
		if distance <= best_distance:
			best_distance = distance
			best = caravan
	return best


## Soldier names already spoken for, so two guards in one county never share one.
func _taken_names() -> Dictionary:
	var taken := {}
	for key in state.soldiers.keys():
		var soldier := state.soldiers[key] as Soldier
		if soldier != null:
			taken["%s %s" % [soldier.first_name, soldier.surname]] = true
	return taken


## Settlements a caravan can start from: places that sell something somebody else wants, and can
## reach that somebody by road. A town with no road to a buyer gets no caravan.
func _starting_settlements() -> Array[Settlement]:
	var starts: Array[Settlement] = []
	var max_units := config.get_float("trade.max_route_units", 1500.0)
	for key in state.settlements.keys():
		var settlement := state.settlements[key] as Settlement
		if settlement == null or settlement.produces.is_empty():
			continue
		var has_route := false
		for route_any in TradeService.best_routes(settlement, state.settlements, 5, max_units):
			var route: Dictionary = route_any as Dictionary
			if not _path_over_links(settlement.id, str(route.get("id", ""))).is_empty():
				has_route = true
				break
		if has_route:
			starts.append(settlement)
	starts.sort_custom(func(a: Settlement, b: Settlement) -> bool: return a.id < b.id)
	return starts
