class_name OverworldService
extends RefCounted
## Spawns and moves the parties that share the map with the player.
##
## Spawning is deterministic: spawn points come from
## [code]data/encounters/bandit_parties.json[/code] and composition is rolled from
## streams derived from the campaign seed, so the same seed always produces the
## same world. Movement is intentionally simple - wander near home, chase the
## player if close - and lives here rather than in the view so it is testable.

const ENCOUNTERS_PATH := "res://data/encounters/bandit_parties.json"

var state: CampaignState = null
var config: GameConfig = null
var units: UnitCatalog = null


static func build(p_state: CampaignState, p_config: GameConfig) -> OverworldService:
	if p_state == null or p_config == null:
		return null
	var service := OverworldService.new()
	service.state = p_state
	service.config = p_config
	service.units = UnitCatalog.load_from()
	return service


## ---------- spawning -----------------------------------------------------

## Creates the world's hostile parties if they do not exist yet. Idempotent, so
## loading a save keeps the parties exactly as they were (including ones already
## wiped out).
func spawn_if_needed() -> bool:
	if not state.parties.is_empty():
		return false
	var data := GameData.load_json(ENCOUNTERS_PATH)
	var templates := {}
	for raw in data.get("templates", []) as Array:
		if typeof(raw) == TYPE_DICTIONARY:
			var record := raw as Dictionary
			templates[str(record.get("id", ""))] = record

	var spawned := 0
	for raw_spawn in data.get("spawns", []) as Array:
		if typeof(raw_spawn) != TYPE_DICTIONARY:
			continue
		var spawn := raw_spawn as Dictionary
		var template: Variant = templates.get(str(spawn.get("template_id", "")), null)
		if typeof(template) != TYPE_DICTIONARY:
			DebugLogger.warn("spawn '%s' references an unknown template" % str(spawn.get("id", "")), "Overworld")
			continue
		if _spawn_party(spawn, template as Dictionary):
			spawned += 1
	DebugLogger.info("overworld spawned %d hostile parties" % spawned, "Overworld")
	return spawned > 0


func _spawn_party(spawn: Dictionary, template: Dictionary) -> bool:
	var spawn_id := str(spawn.get("id", ""))
	var settlement := state.settlement(str(spawn.get("settlement_id", "")))
	if spawn_id.is_empty() or settlement == null:
		DebugLogger.warn("spawn '%s' has no valid settlement" % spawn_id, "Overworld")
		return false

	var origin := settlement.position + DataUtils.vec2_from(spawn.get("offset", [0.0, 0.0]))
	var seed_index := int(spawn.get("seed_index", 1))

	var world_party := WorldParty.new()
	world_party.id = spawn_id
	world_party.party_id = spawn_id
	world_party.display_name = str(template.get("name", "Unknown Party"))
	world_party.kind = str(template.get("kind", Party.KIND_BANDIT))
	world_party.behaviour = str(template.get("behaviour", WorldParty.BEHAVIOUR_WANDER))
	world_party.position = origin
	world_party.home_position = origin
	world_party.destination = origin
	world_party.wander_radius = float(template.get("wander_radius", 120.0))

	var party := Party.new()
	party.id = spawn_id
	party.kind = world_party.kind
	party.display_name = world_party.display_name
	party.faction_id = str(template.get("faction_id", "bandits"))
	party.leader_name = ""

	var roster := _roll_roster(template, seed_index)
	if roster.is_empty():
		DebugLogger.warn("spawn '%s' produced no soldiers" % spawn_id, "Overworld")
		return false
	for soldier in roster:
		state.register_soldier(soldier)
		party.add_member(soldier.id)

	state.parties[world_party.id] = world_party
	state.enemy_parties[party.id] = party
	DebugLogger.info("spawned %s (%d soldiers) near %s" % [
		world_party.display_name, state.active_member_count(party), settlement.name,
	], "Overworld")
	return true


## Rolls a soldier roster for a template, using weighted composition.
func _roll_roster(template: Dictionary, seed_index: int) -> Array[Soldier]:
	var out: Array[Soldier] = []
	var composition: Array = []
	for raw_entry in template.get("composition", []) as Array:
		if typeof(raw_entry) != TYPE_DICTIONARY:
			continue
		var entry := raw_entry as Dictionary
		var unit_type_id := str(entry.get("unit_type_id", ""))
		if not units.has(unit_type_id):
			DebugLogger.warn("composition references unknown unit '%s'" % unit_type_id, "Overworld")
			continue
		var weight := maxi(1, int(entry.get("weight", 1)))
		for i in weight:
			composition.append(unit_type_id)
	if composition.is_empty():
		return out

	var generator := state.rng.stream("roster:%d" % seed_index)
	var size := generator.randi_range(
		int(template.get("size_min", 4)),
		int(template.get("size_max", 6))
	)
	for slot in size:
		var unit_type_id := str(composition[generator.randi_range(0, composition.size() - 1)])
		var soldier := _make_soldier(unit_type_id, seed_index, slot)
		if soldier != null:
			out.append(soldier)
	return out


func _make_soldier(unit_type_id: String, seed_index: int, slot: int) -> Soldier:
	var definition := units.get_definition(unit_type_id)
	if definition == null:
		return null
	var soldier := Soldier.new()
	var index := (seed_index * 100) + slot
	var name_generator := NameGenerator.load_from(state.rng)
	var rolled := name_generator.name_for(index, _taken_names())
	soldier.first_name = str(rolled.get("first_name", "Unnamed"))
	soldier.surname = str(rolled.get("surname", ""))
	soldier.unit_type_id = unit_type_id
	soldier.faction_id = "bandits"
	soldier.age = name_generator.value_for(index, "age", 18, 45)
	soldier.level = 1
	soldier.max_hp = definition.max_hp_at(1, config)
	soldier.hp = soldier.max_hp
	# Bandits are not loyal to anyone, and know it.
	soldier.morale = name_generator.value_for(index, "morale", 45, 75)
	soldier.loyalty = name_generator.value_for(index, "loyalty", 10, 30)
	return soldier


func _taken_names() -> Dictionary:
	var taken := {}
	for key in state.soldiers.keys():
		var soldier := state.soldiers[key] as Soldier
		if soldier != null:
			taken[soldier.full_name()] = true
	return taken


## ---------- movement -----------------------------------------------------

## Advance every undefeated party by [param game_hours]. Returns the number of
## parties that moved.
func step(game_hours: float) -> int:
	if game_hours <= 0.0:
		return 0
	var moved := 0
	for key in state.parties.keys():
		var world_party := state.parties[key] as WorldParty
		if world_party == null or not world_party.is_available():
			continue
		if _step_party(world_party, game_hours):
			moved += 1
	return moved


func _step_party(world_party: WorldParty, game_hours: float) -> bool:
	# Traders are not the overworld's to move (D-139): CaravanService walks them along their road
	# curve, and two steps fighting over one position would make them stutter.
	if world_party.behaviour == WorldParty.BEHAVIOUR_TRADE:
		return false
	var party := state.party_of(world_party)
	if party == null or state.active_members(party).is_empty():
		# A party with nobody left standing is simply gone.
		world_party.defeated = true
		DebugLogger.info("%s has no soldiers left and is removed from the map" % world_party.display_name, "Overworld")
		return false

	var aggro_radius := config.get_float("encounters.aggro_radius", 190.0)
	var speed := base_party_speed() * config.get_float("encounters.speed_multiplier", 0.9)
	var player_position := state.world_position
	var distance_to_player := world_party.position.distance_to(player_position)

	var target := world_party.destination
	if distance_to_player <= aggro_radius and world_party.kind == Party.KIND_BANDIT:
		# Chase: hostile parties close on a nearby player party. Only hostiles - a caravan that
		# hunted the player across the county was the first thing this gate fixed (D-139).
		target = player_position
	else:
		if world_party.behaviour == WorldParty.BEHAVIOUR_STATIONARY:
			return false
		if world_party.position.distance_to(target) <= 8.0:
			target = _pick_wander_target(world_party)
			world_party.destination = target

	var to_target := target - world_party.position
	var travel := speed * game_hours
	if to_target.length() <= travel:
		world_party.position = target
	else:
		world_party.position += to_target.normalized() * travel
	return true


func base_party_speed() -> float:
	return config.get_float("travel.world_units_per_game_hour", 150.0)


## A new wander destination, derived from the party id and how many times it has
## wandered - deterministic without storing random state.
func _pick_wander_target(world_party: WorldParty) -> Vector2:
	world_party.wander_count += 1
	var generator := state.rng.stream("wander:%s:%d" % [world_party.id, world_party.wander_count])
	var angle := generator.randf_range(0.0, TAU)
	var radius := generator.randf_range(world_party.wander_radius * 0.3, world_party.wander_radius)
	var target := world_party.home_position + Vector2(cos(angle), sin(angle)) * radius
	return clamp_to_map(target)


func clamp_to_map(point: Vector2) -> Vector2:
	var size := Vector2(
		config.get_float("world.map_width", 1600.0),
		config.get_float("world.map_height", 900.0)
	)
	return Vector2(
		clampf(point.x, 24.0, size.x - 24.0),
		clampf(point.y, 24.0, size.y - 24.0)
	)


## ---------- queries ------------------------------------------------------

func available_parties() -> Array[WorldParty]:
	var out: Array[WorldParty] = []
	for key in state.parties.keys():
		var world_party := state.parties[key] as WorldParty
		if world_party != null and world_party.is_available():
			out.append(world_party)
	return out


func party_strength(world_party: WorldParty) -> int:
	var party := state.party_of(world_party)
	if party == null:
		return 0
	return state.party_strength(party)
