class_name TravelService
extends RefCounted
## Overworld travel for the player's party.
##
## Pure logic: it moves a position, spends game hours and reports what happened.
## No nodes, no input, no drawing - so the whole "travel to a town, arrive, and
## have the world agree" flow is testable headlessly.
##
## Time is never converted here. The caller advances the [CampaignClock] and
## hands this service the elapsed game hours.

var state: CampaignState
var config: GameConfig


func _init(p_state: CampaignState, p_config: GameConfig) -> void:
	state = p_state
	config = p_config


## ---------- queries ------------------------------------------------------

func is_travelling() -> bool:
	return state != null and (not state.destination_id.is_empty() or state.destination_is_point)


func destination() -> Settlement:
	if state == null:
		return null
	return state.settlement(state.destination_id)


## Where the party is marching to. A destination is usually an enterable town, but the player can
## order a march to any spot on the map, and most of the map is not a town.
func destination_position() -> Vector2:
	if state == null:
		return Vector2.ZERO
	if state.destination_is_point:
		return state.destination_point
	var target := destination()
	return target.position if target != null else state.world_position


## True when the march is to open ground rather than to a settlement.
func is_marching_to_point() -> bool:
	return state != null and state.destination_is_point


func current_settlement() -> Settlement:
	if state == null:
		return null
	return state.settlement(state.current_settlement_id)


## Party size slows the column down, with a floor so a large party is never
## immobilised. All three numbers come from the config.
##
## The size used is the [b]active fieldable[/b] count, not the roster count: dead
## soldiers stay in the party for the historical record and must not keep slowing
## the living down.
## Where the party is on its route, and whether that is a road. Kept when a destination is set, so
## step() follows the same curve the map draws rather than cutting across country.
var route: PackedVector2Array = PackedVector2Array()
## Which settlement the current route is for. Without this the route was built once and kept forever:
## the first order followed the roads and every order after it walked the old road to the old place -
## the owner: "player does it off first command, but then not again".
var _route_target := ""
## The world's field, built lazily: ground_factor() reads it every step and build() is not cheap.
var _world: WorldChunks = null
var route_leg := 0
## The living road network, when the map has one: the party's walking wears the roads it uses, and
## its pace reads the ground's price exactly as the grid priced it. Fixtures that build a travel
## service on their own leave this null, in which case nothing is worn and the field answers alone.
var roads: RoadNetwork = null
## The road accounting for the journey under way: distance walked, distance walked on a road, and
## what the last check found. Every new order resets it, so each arrival line counts its own
## journey.
var _journey_units := 0.0
var _journey_on_road := 0.0
var _journey_max_gap := 0.0
var _journey_hours := 0.0
var _on_road := false
var _road_state_known := false
var _road_check_hours := 0.0
var _road_log_hours := 0.0

## On a road the owner wants speed; off it, the ground decides. Read from the world's own field - the
## same one the map paints from - so a marsh is slow on the map and slow to cross.
func ground_factor() -> float:
	# The drawn road answers first: the walk's pace follows the line the map draws, so the speed
	# changes exactly where a road visibly begins and ends (D-124) - the same corridor the wear scan
	# and the on/off-road log use. Off the line, the open ground's own factor says what the field
	# costs. Without a road network the priced grid (or the route's own legs) still speaks, as ever.
	if roads != null:
		var bonus := roads.bonus_at(state.world_position)
		if bonus > 0.0:
			return bonus
		return _ground_factor_at(state.world_position)
	if costs != null and costs.is_ready():
		return costs.factor_at(state.world_position)
	if is_on_road():
		return config.get_float("travel.road_speed_bonus", 1.4)
	return _ground_factor_at(state.world_position)


## Within about a road's width of the route's current leg, which is the leg the map drew as a road.
func is_on_road() -> bool:
	if route.size() < 2:
		return false
	var width := config.get_float("travel.road_width", 26.0)
	for i in range(maxi(0, route_leg - 1), mini(route.size() - 1, route_leg + 1)):
		var a := route[i]
		var b := route[i + 1]
		var span := b - a
		if span.length() < 0.001:
			continue
		var t := clampf((state.world_position - a).dot(span) / span.length_squared(), 0.0, 1.0)
		if state.world_position.distance_to(a + span * t) <= width:
			return true
	return false


func speed_multiplier() -> float:
	var penalty := config.get_float("travel.party_size_speed_penalty", 0.012)
	var floor_fraction := config.get_float("travel.min_speed_fraction", 0.55)
	var size := 0
	if state != null and state.player_party != null:
		size = state.active_member_count(state.player_party)
	return maxf(floor_fraction, 1.0 - (float(size) * penalty))


func speed_units_per_game_hour() -> float:
	var base := config.get_float("travel.world_units_per_game_hour", 150.0)
	return base * speed_multiplier()


func arrival_radius() -> float:
	return config.get_float("travel.arrival_radius", 16.0)


func distance_to(point: Vector2) -> float:
	if state == null:
		return 0.0
	return state.world_position.distance_to(point)


## The speed factor the ground gives at a point. The drawn roads answer first - the pace and the eta
## both read the line the map draws, so an estimate lands where the walk will actually change speed
## (D-124) - and the priced grid answers for the route's sake. Open ground falls to the raw field
## either way.
func factor_at_point(point: Vector2) -> float:
	if roads != null:
		var bonus := roads.bonus_at(point)
		if bonus > 0.0:
			return bonus
		return _ground_factor_at(point)
	if costs != null and costs.is_ready():
		return costs.factor_at(point)
	return _ground_factor_at(point)


## How far apart the eta's samples are, in world units.
const ETA_SAMPLE_UNITS := 32.0
## How much game time passes between road-state checks while travelling. The owner watched the map
## and said the party "visually... aren't following the roads"; this is the cadence at which the
## log says where the party actually stands relative to the links it should be walking.
const ROAD_CHECK_HOURS := 0.1
## How far apart the route is sampled when looking for road stretches to snap onto the drawn line,
## in world units.
const SNAP_SAMPLE_UNITS := 16.0


## Game hours the party needs to reach a point, priced along the line rather than at one end: a
## journey over a marsh costs more than one over grass, and an eta taken while standing on a road
## no longer quotes the whole distance at road speed. Used for UI estimates; the route itself is
## priced by the grid when one exists.
func hours_to_reach(point: Vector2) -> float:
	if state == null:
		return 0.0
	var distance := distance_to(point)
	var speed := speed_units_per_game_hour()
	if speed <= 0.0 or distance <= 0.0:
		return 0.0
	var samples := maxi(2, int(ceil(distance / ETA_SAMPLE_UNITS)) + 1)
	var hours := 0.0
	var previous := state.world_position
	for i in range(1, samples + 1):
		var at: Vector2 = state.world_position.lerp(point, float(i) / float(samples))
		var factor := factor_at_point(previous.lerp(at, 0.5))
		hours += previous.distance_to(at) / (speed * maxf(0.05, factor))
		previous = at
	return hours


func is_at_settlement(settlement_id: String) -> bool:
	if state == null:
		return false
	return state.current_settlement_id == settlement_id and is_within_settlement(state.settlement(settlement_id))


func is_within_settlement(settlement: Settlement) -> bool:
	if settlement == null:
		return false
	return distance_to(settlement.position) <= arrival_radius()


## ---------- commands -----------------------------------------------------

## Begin travelling toward a settlement. Returns false when the order makes no
## sense (unknown destination, or already standing there).
## The route from here to there, through the road network, as a single polyline of the same curves
## the map draws. Breadth-first over the road edges: the network has a few dozen nodes, so a shortest
## path by hops is found instantly and, because roads are faster, the fewest-road route is usually the
## quickest one too.
## The closest settlement to where the party stands, for joining the road network from open country.
## What a route costs in game hours: every leg at the speed the ground gives it. Road legs carry the
## road bonus because being on a road is exactly what the ground check reports; everything else is
## sampled from the field at the leg's midpoint, so a marsh costs more than open country and a route
## through one is priced accordingly.
func _hours_for(points: PackedVector2Array, along_roads: bool) -> float:
	var hours := 0.0
	var base := maxf(1.0, speed_units_per_game_hour())
	for i in points.size() - 1:
		var a := points[i]
		var b := points[i + 1]
		var span := a.distance_to(b)
		if span <= 0.001:
			continue
		var factor := _ground_factor_at(a.lerp(b, 0.5))
		if along_roads:
			# The road bonus belongs to the road route and nowhere else - without this the road was
			# priced as if it were open country and the straight line won every comparison.
			factor = maxf(factor, config.get_float("travel.road_speed_bonus", 1.4))
		hours += span / (base * maxf(0.05, factor))
	return hours


## The ground's factor at a point, without disturbing the party's own reading of where it stands.
func _ground_factor_at(point: Vector2) -> float:
	if _world == null:
		_world = WorldChunks.build(state.campaign_seed)
	var here: Dictionary = _world.sample(point)
	var height := float(here.get("height", 0.5))
	var wear := float(here.get("wear", 0.0))
	var moisture := float(here.get("moisture", 0.5))
	if height < config.get_float("travel.water_height", 0.335):
		return config.get_float("travel.water_speed_factor", 0.30)
	if height < config.get_float("travel.marsh_height", 0.375):
		return config.get_float("travel.marsh_speed_factor", 0.55)
	return 1.1 if wear > 0.5 else (0.9 if moisture > 0.6 else 1.0)


func nearest_settlement() -> Settlement:
	var best: Settlement = null
	var best_distance := INF
	for key in state.settlements.keys():
		var candidate := state.settlements[key] as Settlement
		if candidate == null:
			continue
		var d := state.world_position.distance_to(candidate.position)
		if d < best_distance:
			best_distance = d
			best = candidate
	return best


## The cost grid and its pathfinder. Built by the map once per campaign; the travel service only reads
## it. With no grid there is no pathfinding and journeys walk straight, which is also what a test with no
## world gets.
var costs: TravelCosts = null


func build_route(to: Settlement) -> void:
	route = PackedVector2Array()
	route_leg = 0
	if costs != null and costs.is_ready() and to != null:
		# One path, priced by the ground and by the roads, with no comparison to make: a road is cheap
		# cells and a marsh is dear ones, and the pathfinder has one job. The pathfinder's answer is
		# made of cell centres; the road stretches of it are then spliced onto the drawn curves so
		# the walk is the line the player can see.
		route = _snap_to_roads(costs.path_between(state.world_position, to.position))
		_log_route_share()
		return
	var from := current_settlement()
	if from == null:
		# Out in the wild: head for the nearest town, which puts the party onto the network instead of
		# ignoring it. Without this the route was never built unless the party was already standing in a
		# settlement, and the owner saw exactly that: "still don't follow the roads."
		from = nearest_settlement()
	if from == null or to == null or from.id == to.id:
		return
	var edges := {}
	for road in state.roads:
		var a := str(road.get("a", ""))
		var b := str(road.get("b", ""))
		edges[a] = (edges.get(a, []) as Array) + [b]
		edges[b] = (edges.get(b, []) as Array) + [a]
	var came := {from.id: ""}
	var queue: Array[String] = [from.id]
	var found := false
	while not queue.is_empty() and not found:
		var here: String = queue.pop_front()
		for next in (edges.get(here, []) as Array):
			var id := str(next)
			if came.has(id):
				continue
			came[id] = here
			if id == to.id:
				found = true
				break
			queue.append(id)
	if not found:
		return
	var chain: Array[String] = []
	var step := to.id
	while step != from.id and step != "":
		chain.push_front(step)
		step = str(came.get(step, ""))
	# Walk the chain backwards into waypoints, drawing each leg through RoadPath so the party's line
	# and the map's line are the same line.
	var points := PackedVector2Array([state.world_position])
	var previous := from
	if _world == null:
		_world = WorldChunks.build(state.campaign_seed)
	for id in chain:
		var node := state.settlement(id)
		if node == null:
			continue
		var shaped := RoadPath.between(previous.position, node.position, _world,
			config.get_float("travel.water_height", 0.335),
			config.get_float("roads.bridge_max_span", 64.0))
		for point in shaped:
			points.append(point)
		previous = node
	points.append(to.position)

	# Both ways are now costed, and the cheaper one wins. A road is faster per unit, not always shorter:
	# a road that loops half the map to save forty per cent of your speed is a worse journey than walking
	# straight, and the owner's point exactly - "the player ignores going over terrain all together, even
	# when it makes sense to follow the terrain instead of the road."
	var direct := PackedVector2Array([state.world_position, to.position])
	var road_hours := _hours_for(points, true)
	var direct_hours := _hours_for(direct, false)
	if direct_hours < road_hours:
		route = direct
		print("travel: straight over the land, %.1f h against %.1f by road" % [direct_hours, road_hours])
	else:
		route = points
		print("travel: along the roads, %.1f h against %.1f straight" % [road_hours, direct_hours])
	_log_route_share()


## Replace the stretches of a route that run along a road with that road's own curve - the same
## points the map draws - so the marker walks the line instead of a chain of cell-centre chords
## beside it. The owner, watching it: "I see my pawn moving in a straight line... I think the game
## thinks that block is road" - and it did: the grid prices blocks, the drawing is a line, and the
## walk split the difference. Where the route is genuinely off-road the pathfinder's own line
## stands; only corridor stretches change, and both endpoints are kept exactly.
func _snap_to_roads(points: PackedVector2Array) -> PackedVector2Array:
	if roads == null or points.size() < 2:
		return points
	var radius := roads.road_radius()
	var snapped := PackedVector2Array()
	snapped.append(points[0])
	var run_link := -1
	var run_entry := points[0]
	for i in range(1, points.size()):
		var a := points[i - 1]
		var b := points[i]
		var span := a.distance_to(b)
		var steps := maxi(1, int(ceil(span / SNAP_SAMPLE_UNITS)))
		for s in range(1, steps + 1):
			var at: Vector2 = a.lerp(b, float(s) / float(steps))
			var link := roads.nearest_link(at, radius)
			if link != run_link:
				if run_link >= 0:
					_splice_curve(snapped, run_link, run_entry, at)
				run_link = link
				run_entry = at
		if run_link < 0:
			# Off-road: the pathfinder's own line stands, corner for corner.
			snapped.append(b)
	if run_link >= 0:
		_splice_curve(snapped, run_link, run_entry, points[points.size() - 1])
	var destination: Vector2 = points[points.size() - 1]
	if snapped[snapped.size() - 1].distance_to(destination) > 0.001:
		snapped.append(destination)
	return snapped


## Append a link's own curve between the two stretch ends, in the order the route met them: the
## index order is the walk's order, so a route heading for one end of a link and one heading for
## the other both come out right.
func _splice_curve(out: PackedVector2Array, link: int, from_point: Vector2, to_point: Vector2) -> void:
	var curve := roads.link_curve(link)
	if curve.size() < 2:
		return
	var first := _nearest_curve_index(curve, from_point)
	var last := _nearest_curve_index(curve, to_point)
	var step := 1 if last >= first else -1
	var index := first
	while true:
		var at := curve[index]
		if out[out.size() - 1].distance_to(at) > 0.01:
			out.append(at)
		if index == last:
			break
		index += step


## The curve index nearest a point: where a route stretch enters or leaves the drawn line.
func _nearest_curve_index(curve: PackedVector2Array, point: Vector2) -> int:
	var best := INF
	var found := 0
	for i in curve.size():
		var distance := curve[i].distance_squared_to(point)
		if distance < best:
			best = distance
			found = i
	return found


## Say what the route that was just built is made of: how much of its length runs on a road. The
## owner, watching the map: "visually they aren't following the roads" - this is the number that
## separates "the picture is wrong" from "the path was never on the road".
func _log_route_share() -> void:
	if roads == null or route.size() < 2:
		return
	var total := 0.0
	var on_road_units := 0.0
	var previous := route[0]
	for i in range(1, route.size()):
		var point := route[i]
		var span := previous.distance_to(point)
		if span > 0.0001:
			var samples := maxi(1, int(ceil(span / ETA_SAMPLE_UNITS)))
			for s in range(1, samples + 1):
				var at: Vector2 = previous.lerp(point, float(s) / float(samples))
				total += span / float(samples)
				if roads.on_road(at):
					on_road_units += span / float(samples)
		previous = point
	if total > 0.0:
		DebugLogger.info("travel: route is %.0f%% on roads (%.0f units)" % [
			100.0 * on_road_units / total, total,
		], "Travel")


## A new order resets the journey's road accounting, so each arrival line counts its own journey.
func _begin_journey() -> void:
	_journey_units = 0.0
	_journey_on_road = 0.0
	_journey_max_gap = 0.0
	_journey_hours = 0.0
	_on_road = false
	_road_state_known = false
	_road_check_hours = 0.0
	_road_log_hours = 0.0


## The journey's verdict, in the same units as the route line: how much of what was actually
## walked lay on a road, and how far off a line the walk wandered at its worst.
func _log_journey_share() -> void:
	if roads == null or _journey_units <= 1.0:
		return
	DebugLogger.info("travel: journey ends - %.0f%% of %.0f units walked on roads at ~%.0f u/h, worst %.0f u off a line" % [
		100.0 * _journey_on_road / _journey_units, _journey_units,
		_journey_units / maxf(_journey_hours, 0.0001), _journey_max_gap,
	], "Travel")


## Say where the party stands relative to the roads: a line whenever that changes, and a periodic
## trace while it does not, because the transition lines alone cannot say whether the walk hugs the
## drawn line or merely stays inside the corridor the wear counts.
func _watch_road_state(game_hours: float) -> void:
	_road_check_hours += game_hours
	if _road_state_known and _road_check_hours < ROAD_CHECK_HOURS:
		return
	_road_check_hours = 0.0
	var here := state.world_position
	var on := roads.on_road(here)
	var gap := roads.distance_to_nearest_link(here)
	_journey_max_gap = maxf(_journey_max_gap, gap)
	var who := roads.link_label(roads.nearest_link(here, -1.0))
	# The pace the log can be checked against: the same factor the walk is using at this instant,
	# so a transition line and a speed change are one event, not two to be correlated later.
	var factor := ground_factor()
	var line := ""
	if on:
		line = "travel: on the road - %s, %.0f u off its line (ground x%.2f)" % [who, gap, factor]
	elif who.is_empty():
		line = "travel: off the road - %.0f u from any link (ground x%.2f)" % [gap, factor]
	else:
		line = "travel: off the road - %.0f u from %s (ground x%.2f)" % [gap, who, factor]
	if not _road_state_known or on != _on_road:
		DebugLogger.info(line, "Travel")
		_on_road = on
		_road_state_known = true
		_road_log_hours = 0.0
		return
	_road_log_hours += ROAD_CHECK_HOURS
	if _road_log_hours >= 0.5:
		_road_log_hours = 0.0
		DebugLogger.info(line, "Travel")


func set_destination(settlement_id: String) -> bool:
	if state == null:
		return false
	var was_travelling := is_travelling()
	var walked := _journey_units
	state.destination_is_point = false
	var target := state.settlement(settlement_id)
	if target == null:
		DebugLogger.warn("travel order for unknown settlement '%s'" % settlement_id, "Travel")
		return false
	if not target.is_enterable():
		DebugLogger.info("cannot travel to %s: not an enterable location" % target.name, "Travel")
		return false
	if is_within_settlement(target):
		# Standing here already. Record it as the current location, but do not
		# cancel an unrelated journey in progress - a stray click on the town you
		# are standing in should be a no-op, not an order to stop.
		state.current_settlement_id = target.id
		if state.destination_id == target.id:
			state.destination_id = ""
		DebugLogger.info("travel: already standing at %s - order ignored" % target.name, "Travel")
		return false
	state.destination_id = target.id
	state.current_settlement_id = ""
	if was_travelling and walked > 1.0:
		DebugLogger.info("travel: order replaced - %.0f u of the old journey already walked" % walked, "Travel")
	_begin_journey()
	DebugLogger.info("travelling to %s (%.0f units, ~%.1f game hours)" % [
		target.name, distance_to(target.position), hours_to_reach(target.position),
	], "Travel")
	return true


## March to a spot on the map rather than to a settlement. This is the right-click move order, and
## it exists because a settlement-only travel order refuses most of the map: any place that cannot
## be entered - a hamlet, a ruin, a crossroads - could not be marched to at all. See D-109.
func set_destination_point(point: Vector2) -> bool:
	if state == null:
		return false
	var span := state.world_position.distance_to(point)
	if span <= arrival_radius():
		DebugLogger.info("march refused: already at the spot (%.0f u away)" % span, "Travel")
		return false
	var was_travelling := is_travelling()
	var walked := _journey_units
	state.destination_is_point = true
	state.destination_point = point
	state.destination_id = ""
	state.current_settlement_id = ""
	# A point march is always walked straight: any route a settlement order left behind is dropped,
	# or the party keeps following the old road to the old place and "arrives" the moment it is
	# ordered - the owner: "I can't click on random spots, only locations (settlements)".
	route = PackedVector2Array()
	route_leg = 0
	_route_target = ""
	if was_travelling and walked > 1.0:
		DebugLogger.info("travel: order replaced - %.0f u of the old journey already walked" % walked, "Travel")
	_begin_journey()
	DebugLogger.info("marching to open ground (%.0f units, ~%.1f game hours)" % [
		distance_to(point), hours_to_reach(point),
	], "Travel")
	return true


func clear_destination() -> void:
	var was_travelling := is_travelling()
	var walked := _journey_units
	if state != null:
		state.destination_id = ""
		state.destination_is_point = false
	if was_travelling and walked > 1.0:
		DebugLogger.info("travel: order cleared - %.0f u of the journey already walked" % walked, "Travel")
	# Cancelling drops the route with the order, so the next march starts from where the party
	# actually stands rather than continuing the road it was on.
	route = PackedVector2Array()
	route_leg = 0
	_route_target = ""


## Advance travel by [param game_hours]. Returns a small report dictionary:
## [code]{"moved": bool, "arrived": bool, "settlement_id": String,
## "distance_travelled": float}[/code]
## The party walks a polyline. That is the whole model, and it is worth saying because everything that
## made this hard - targets, arrival radii, snapping to waypoints, re-routing on identity - existed only
## because routing was bolted onto a step that chased a single destination point, and the seams between
## the two kept showing. The owner, correctly: "the travel on a road should not be this hard."
##
## route is a list of world points. A step spends a budget of distance walking along it by arc length:
## find where the party is on the current segment, walk as far as the budget allows, and carry whatever
## is left into the next segment. No snapping, no special cases, no radius except the one that ends the
## journey at its true end.
func step(game_hours: float) -> Dictionary:
	var report := {
		"moved": false,
		"arrived": false,
		"settlement_id": "",
		"distance_travelled": 0.0,
	}
	if state == null or game_hours <= 0.0 or not is_travelling():
		return report

	# Where the party stood before this step, so the ground it just walked can be handed to the
	# road network afterwards.
	var start_point := state.world_position

	# A new destination routes, once. Keyed on identity so every order works rather than only the first.
	var wanted := destination()
	if wanted != null and str(wanted.id) != _route_target:
		_route_target = str(wanted.id)
		route = PackedVector2Array()
		route_leg = 0
		build_route(wanted)

	if route.size() < 2:
		# No route - marching to open ground, or a destination with no road between: a straight walk.
		var straight := _step_straight(game_hours, report)
		_report_walk(start_point, game_hours, straight)
		return straight

	# Never more than a step's worth of distance, however much game time the step was handed, and
	# never more than the ground gives: the pace reads the same factor the grid priced into the route.
	var budget := minf(speed_units_per_game_hour() * ground_factor() * game_hours, config.get_float("travel.max_step_units", 24.0))
	var spent := 0.0
	var leg := route_leg
	while budget > 0.0 and leg < route.size() - 1:
		var a := route[leg]
		var b := route[leg + 1]
		var seg := b - a
		var seg_len := seg.length()
		if seg_len < 0.0001:
			leg += 1
			continue
		var t := clampf((state.world_position - a).dot(seg) / (seg_len * seg_len), 0.0, 1.0)
		var to_end := (1.0 - t) * seg_len
		if budget >= to_end:
			state.world_position = b
			budget -= to_end
			spent += to_end
			leg += 1
		else:
			state.world_position = a.lerp(b, t) + seg.normalized() * budget
			spent += budget
			budget = 0.0
	route_leg = leg
	report["moved"] = true
	report["distance_travelled"] = spent

	# Arriving is reaching the end of the route, and only that.
	if leg >= route.size() - 1 and state.world_position.distance_to(route[route.size() - 1]) <= arrival_radius():
		_finish_travel(report)
	_report_walk(start_point, game_hours, report)
	return report


## A straight walk to the destination, for journeys with no road under them.
func _step_straight(game_hours: float, report: Dictionary) -> Dictionary:
	var target := destination_position()
	var to_target := target - state.world_position
	var distance := to_target.length()
	if distance <= arrival_radius():
		_finish_travel(report)
		return report
	var travel := minf(speed_units_per_game_hour() * ground_factor() * game_hours, config.get_float("travel.max_step_units", 24.0))
	if travel >= distance:
		state.world_position = target
		report["distance_travelled"] = distance
		if destination() != null:
			_finish_travel(report)
		return report
	state.world_position += to_target.normalized() * travel
	report["moved"] = true
	report["distance_travelled"] = travel
	return report


## Hand what was just walked to the road network and to the journey's own accounting: wear for the
## link that was used, and the on-road ledger the travel log reports. The network throttles its own
## scans; this only reports what happened.
func _report_walk(from_point: Vector2, game_hours: float, report: Dictionary) -> void:
	if roads == null:
		return
	var walked := float(report.get("distance_travelled", 0.0))
	if walked <= 0.001:
		return
	roads.charge_move(from_point, state.world_position, walked, game_hours)
	if _on_road:
		_journey_on_road += walked
	_journey_units += walked
	_journey_hours += game_hours
	_watch_road_state(game_hours)


## Teleport (debug panel / tests). Skips travel entirely but still consumes no time.
func teleport_to(settlement_id: String) -> bool:
	if state == null:
		return false
	var target := state.settlement(settlement_id)
	if target == null:
		return false
	state.world_position = target.position
	state.destination_id = ""
	state.current_settlement_id = target.id
	target.visited = true
	DebugLogger.info("teleported to %s" % target.name, "Travel")
	return true


## Arriving at whatever the party was marching to. A settlement is entered and marked visited; open
## ground is simply where the march ends, so the order clears and the clock carries on.
func _finish_travel(report: Dictionary) -> void:
	_log_journey_share()
	if state.destination_is_point:
		state.destination_is_point = false
		report["arrived"] = true
		report["settlement_id"] = ""
		# A point order can still land the party on a place - a march aimed at a hamlet, or at a
		# spot just inside a town's radius. Where the party stands is then that place, and saying so
		# is what lets the panel offer to open it. Without this a point order left the player
		# standing on a town with nothing to click.
		var here := _settlement_at(state.world_position)
		if here != null:
			state.current_settlement_id = here.id
			here.visited = true
			report["settlement_id"] = here.id
			DebugLogger.info("arrived at %s on %s" % [here.name, state.clock.full_string()], "Travel")
			return
		DebugLogger.info("arrived at open ground on %s" % state.clock.full_string(), "Travel")
		return
	var target := destination()
	if target == null:
		state.destination_id = ""
		return
	_arrive(target, report)


## The settlement the party is standing in, if any. The arrival radius is the same test the travel
## order uses, so "standing there" means one thing in this file.
func _settlement_at(point: Vector2) -> Settlement:
	if state == null:
		return null
	for settlement in state.settlements.values():
		if point.distance_to(settlement.position) <= arrival_radius():
			return settlement
	return null


func _arrive(target: Settlement, report: Dictionary) -> void:
	state.destination_id = ""
	state.current_settlement_id = target.id
	target.visited = true
	report["arrived"] = true
	report["settlement_id"] = target.id
	DebugLogger.info("arrived at %s on %s" % [target.name, state.clock.full_string()], "Travel")
