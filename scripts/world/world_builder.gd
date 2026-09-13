class_name WorldBuilder
extends RefCounted
## Turns the settlement data files into live [Settlement] records on a campaign.
##
## Idempotent by design: [method build_if_needed] only builds when the campaign
## has no settlements, so loading a save keeps the saved world state (visited
## flags, depleted recruit pools, later on faction ownership) while a fresh
## campaign gets the authored starting region.

const SETTLEMENTS_PATH := "res://data/settlements/settlements.json"

var state: CampaignState
var config: GameConfig


func _init(p_state: CampaignState, p_config: GameConfig) -> void:
	state = p_state
	config = p_config


## Returns true when the world was built, false when it already existed.
func build_if_needed() -> bool:
	if state == null:
		return false
	if not state.settlements.is_empty():
		return false
	build()
	return true


func build() -> void:
	if state == null:
		return
	state.settlements.clear()
	state.roads.clear()

	var data := GameData.load_json(SETTLEMENTS_PATH)
	for raw in data.get("settlements", []) as Array:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var settlement := _build_settlement(raw as Dictionary)
		if settlement == null:
			continue
		state.settlements[settlement.id] = settlement

	for raw_road in data.get("roads", []) as Array:
		if typeof(raw_road) != TYPE_DICTIONARY:
			continue
		var road := raw_road as Dictionary
		var a := str(road.get("a", ""))
		var b := str(road.get("b", ""))
		if a.is_empty() or b.is_empty():
			continue
		if not state.settlements.has(a) or not state.settlements.has(b):
			DebugLogger.warn("road references unknown settlement (%s -> %s)" % [a, b], "WorldBuilder")
			continue
		state.roads.append({
			"a": a,
			"b": b,
			"kind": str(road.get("kind", "road")),
		})

	_place_player_party()
	DebugLogger.info("world built: %d settlements, %d roads" % [
		state.settlements.size(), state.roads.size(),
	], "WorldBuilder")


func _build_settlement(raw: Dictionary) -> Settlement:
	var settlement := Settlement.new()
	settlement.id = str(raw.get("id", ""))
	if settlement.id.is_empty():
		DebugLogger.error("settlement entry has no id", "WorldBuilder")
		return null
	settlement.name = str(raw.get("name", settlement.id))
	settlement.type = str(raw.get("type", Settlement.TYPE_TOWN))
	settlement.description = str(raw.get("description", ""))
	settlement.position = DataUtils.vec2_from(raw.get("position", [0.0, 0.0]))
	settlement.owner_faction_id = str(raw.get("owner_faction_id", ""))
	settlement.population = int(raw.get("population", 0))
	settlement.market = (raw.get("market", {}) as Dictionary).duplicate(true)
	settlement.last_restock_day = state.clock.day if state.clock != null else 1

	settlement.recruit_pool.clear()
	settlement.recruit_pool_base.clear()
	for key in (raw.get("recruit_pool", {}) as Dictionary).keys():
		var count := int((raw.get("recruit_pool", {}) as Dictionary)[key])
		settlement.recruit_pool[str(key)] = count
		settlement.recruit_pool_base[str(key)] = count
	return settlement


## A brand-new campaign starts the party at the configured starting settlement.
func _place_player_party() -> void:
	if state.world_position != Vector2.ZERO:
		return
	var start_id := config.get_string("world.start_settlement_id", "")
	var start := state.settlement(start_id)
	if start == null and not state.settlements.is_empty():
		start = state.settlements.values()[0] as Settlement
		start_id = start.id
	if start == null:
		return
	state.world_position = start.position
	state.current_settlement_id = start_id
	DebugLogger.info("player party placed at %s" % start.name, "WorldBuilder")
