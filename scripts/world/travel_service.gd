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
	return state != null and not state.destination_id.is_empty()


func destination() -> Settlement:
	if state == null:
		return null
	return state.settlement(state.destination_id)


func current_settlement() -> Settlement:
	if state == null:
		return null
	return state.settlement(state.current_settlement_id)


## Party size slows the column down, with a floor so a large party is never
## immobilised. All three numbers come from the config.
func speed_multiplier() -> float:
	var penalty := config.get_float("travel.party_size_speed_penalty", 0.012)
	var floor_fraction := config.get_float("travel.min_speed_fraction", 0.55)
	var size := state.player_party.size() if state != null and state.player_party != null else 0
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
	var speed := speed_units_per_game_hour()
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
func set_destination(settlement_id: String) -> bool:
	if state == null:
		return false
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


func clear_destination() -> void:
	if state != null:
		state.destination_id = ""


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
	if state == null or game_hours <= 0.0 or state.destination_id.is_empty():
		return report
	var target := destination()
	if target == null:
		state.destination_id = ""
		return report

	var to_target := target.position - state.world_position
	var distance := to_target.length()
	var radius := arrival_radius()

	if distance <= radius:
		_arrive(target, report)
		return report

	var travel := speed_units_per_game_hour() * game_hours
	if distance - travel <= radius:
		# Close enough to finish this step exactly on the destination.
		report["distance_travelled"] = distance
		state.world_position = target.position
		_arrive(target, report)
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


func _arrive(target: Settlement, report: Dictionary) -> void:
	state.destination_id = ""
	state.current_settlement_id = target.id
	target.visited = true
	report["arrived"] = true
	report["settlement_id"] = target.id
	DebugLogger.info("arrived at %s on %s" % [target.name, state.clock.full_string()], "Travel")
