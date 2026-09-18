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

## On a road the owner wants speed; off it, the ground decides. Read from the world's own field - the
## same one the map paints from - so a marsh is slow on the map and slow to cross.
func ground_factor() -> float:
	if is_on_road():
		return config.get_float("travel.road_speed_bonus", 1.4)
	# Built once and kept: this runs every simulation step, and WorldChunks.build() generates a field.
	if _world == null:
		_world = WorldChunks.build(state.campaign_seed)
	var here: Dictionary = _world.sample(state.world_position)
	var height := float(here.get("height", 0.5))
	var wear := float(here.get("wear", 0.0))
	var moisture := float(here.get("moisture", 0.5))
	if height < config.get_float("travel.water_height", 0.335):
		return config.get_float("travel.water_speed_factor", 0.30)
	if height < config.get_float("travel.marsh_height", 0.375):
		return config.get_float("travel.marsh_speed_factor", 0.55)
	# Worn country is where the roads of the world already are: old traffic made it easy going.
	return 1.1 if wear > 0.5 else (0.9 if moisture > 0.6 else 1.0)


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


## Game hours the party needs to reach a point. Used for UI estimates.
func hours_to_reach(point: Vector2) -> float:
	var speed := speed_units_per_game_hour() * ground_factor()
	if speed <= 0.0:
		return 0.0
	return distance_to(point) / speed


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


func build_route(to: Settlement) -> void:
	route = PackedVector2Array()
	route_leg = 0
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
	for id in chain:
		var node := state.settlement(id)
		if node == null:
			continue
		for point in RoadPath.between(previous.position, node.position):
			points.append(point)
		previous = node
	points.append(to.position)
	route = points


func set_destination(settlement_id: String) -> bool:
	if state == null:
		return false
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
		return false
	state.destination_id = target.id
	state.current_settlement_id = ""
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
	if state.world_position.distance_to(point) <= arrival_radius():
		return false
	state.destination_is_point = true
	state.destination_point = point
	state.destination_id = ""
	state.current_settlement_id = ""
	DebugLogger.info("marching to open ground (%.0f units, ~%.1f game hours)" % [
		distance_to(point), hours_to_reach(point),
	], "Travel")
	return true


func clear_destination() -> void:
	if state != null:
		state.destination_id = ""
		state.destination_is_point = false


## Advance travel by [param game_hours]. Returns a small report dictionary:
## [code]{"moved": bool, "arrived": bool, "settlement_id": String,
## "distance_travelled": float}[/code]
func step(game_hours: float) -> Dictionary:
	var report := {
		"moved": false,
		"arrived": false,
		"settlement_id": "",
		"distance_travelled": 0.0,
	}
	if state == null or game_hours <= 0.0 or not is_travelling():
		return report
	# The first step after a destination is set routes through the road network, once. After that the
	# party walks the route's own points, so its line on the map is the line the map drew.
	var wanted := destination()
	if wanted != null and str(wanted.id) != _route_target:
		# A new destination, or the first: route it now. Re-routing on *identity*, not on emptiness,
		# is what makes every order work rather than only the first.
		_route_target = str(wanted.id)
		route = PackedVector2Array()
		route_leg = 0
		build_route(wanted)
	if route.size() >= 2:
		while route_leg < route.size() - 1 and state.world_position.distance_to(route[route_leg + 1]) < 2.0:
			route_leg += 1
	var target := destination_position()
	if route.size() >= 2 and route_leg < route.size() - 1:
		target = route[route_leg + 1]
	var to_target := target - state.world_position
	var distance := to_target.length()
	var radius := arrival_radius()
	# Reaching the *end of the route* is arriving. Reaching a waypoint on the way is not - and until
	# this distinction existed, step() called _finish_travel() at the first bend it passed, so the
	# party stopped in the middle of a road. The owner: "pathing has gotten weird it stops now."
	var final_leg := route.size() < 2 or route_leg >= route.size() - 1

	if distance <= radius:
		if final_leg:
			_finish_travel(report)
			return report
		# Step onto the waypoint and carry on: the journey is not over.
		route_leg += 1
		report["moved"] = true
		report["distance_travelled"] = distance
		return report

	# Cap one step's travel. The first step after an order can carry a long block of accumulated game
	# time and fling the party most of the way to its destination in a single tick - the owner: "first
	# movement command for some reason it is quick af". A step is a step, however much time it owes.
	var travel := minf(speed_units_per_game_hour() * game_hours, config.get_float("travel.max_step_units", 24.0))
	# Never overshoot a waypoint to reach the next one: the party moves toward the point immediately
	# ahead and no further, which is what keeps it on the curve instead of cutting the corner. The
	# owner: "like the curvature and everything needs to be followed."
	if not final_leg and travel >= distance:
		state.world_position = target
		route_leg += 1
		report["moved"] = true
		report["distance_travelled"] = distance
		return report
	if distance - travel <= radius:
		state.world_position = target
		report["distance_travelled"] = distance
		if final_leg:
			# Close enough to finish this step exactly on the destination.
			_finish_travel(report)
			return report
		route_leg += 1
		report["moved"] = true
		return report

	state.world_position += to_target.normalized() * travel
	report["moved"] = true
	report["distance_travelled"] = travel
	return report


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
