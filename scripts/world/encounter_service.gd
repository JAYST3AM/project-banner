class_name EncounterService
extends RefCounted
## Turns "two parties are close together on the map" into a [BattleContext].
##
## Split from [OverworldService] on purpose: that service owns where parties are
## and where they go, this one owns the rules for meeting them - when a meeting is
## a real encounter, what the two sides look like on paper, and how a retreat is
## recorded. Building the context is the point: the battle scene is handed a
## finished description of the fight and never has to go looking for one.

var state: CampaignState = null
var config: GameConfig = null
var units: UnitCatalog = null
var traits: TraitCatalog = null


static func build(p_state: CampaignState, p_config: GameConfig) -> EncounterService:
	if p_state == null or p_config == null:
		return null
	var service := EncounterService.new()
	service.state = p_state
	service.config = p_config
	service.units = UnitCatalog.load_from()
	service.traits = TraitCatalog.load_from()
	return service


## ---------- detection ----------------------------------------------------

func trigger_radius() -> float:
	return config.get_float("encounters.trigger_radius", 26.0)


func cooldown_hours() -> float:
	return config.get_float("encounters.cooldown_hours", 3.0)


func is_on_cooldown(world_party: WorldParty) -> bool:
	if world_party == null:
		return true
	return _now_hours() < world_party.encounter_cooldown_until_hours


func _now_hours() -> float:
	return state.clock.total_hours() if state != null and state.clock != null else 0.0


## The nearest party the player is currently standing on top of, or null.
func detect() -> WorldParty:
	if state == null:
		return null
	var best: WorldParty = null
	var best_distance := trigger_radius()
	for key in state.parties.keys():
		var world_party := state.parties[key] as WorldParty
		if world_party == null or not world_party.is_available():
			continue
		if is_on_cooldown(world_party):
			continue
		var party := state.party_of(world_party)
		if party == null or state.active_members(party).is_empty():
			continue
		var distance := state.world_position.distance_to(world_party.position)
		if distance <= best_distance:
			best_distance = distance
			best = world_party
	return best


## ---------- strength -----------------------------------------------------

func player_strength() -> int:
	return state.party_strength(state.player_party)


func enemy_strength(world_party: WorldParty) -> int:
	var party := state.party_of(world_party)
	if party == null:
		return 0
	return state.party_strength(party)


func enemy_size(world_party: WorldParty) -> int:
	var party := state.party_of(world_party)
	if party == null:
		return 0
	return state.active_members(party).size()


## ---------- context ------------------------------------------------------

## Assemble everything the battle needs. [param attacker_player] is false when an
## enemy party has caught the player, which is what the future ambush path needs.
func build_context(world_party: WorldParty, attacker_player: bool = true) -> BattleContext:
	var enemy_party := state.party_of(world_party)
	if world_party == null or enemy_party == null:
		DebugLogger.warn("cannot build a battle context without an enemy party", "Encounter")
		return null

	# Starting a fight also stops it re-triggering the instant the player returns
	# to the map. Resolving a battle overwrites this with the real outcome.
	world_party.encounter_cooldown_until_hours = _now_hours() + cooldown_hours()

	var context := BattleContext.new()
	var counter := _next_battle_counter()
	context.battle_id = "battle_%04d" % counter
	context.battle_kind = BattleContext.KIND_FIELD
	context.world_party_id = world_party.id
	context.enemy_party_id = enemy_party.id
	context.player_party_id = state.player_party.id
	context.enemy_display_name = world_party.display_name

	context.player_snapshot = _snapshot_party(state.player_party)
	context.enemy_snapshot = _snapshot_party(enemy_party)

	context.world_position = state.world_position
	context.campaign_day = state.clock.day
	context.campaign_hour = state.clock.hour
	# Weather is a placeholder until the battlefield system exists; it is carried
	# in the context now so adding it later does not change this interface.
	context.weather = "clear"

	# Seeds are derived from the campaign seed plus the battle number, so the same
	# campaign always generates the same ground for the same fight.
	context.terrain_seed = state.rng.derive_seed("terrain:%d:%d" % [
		counter, config.get_int("battle.terrain_seed_salt", 17),
	])
	context.battle_seed = state.rng.derive_seed("battle:%d:%d" % [
		counter, config.get_int("battle.battle_seed_salt", 91),
	])

	if attacker_player:
		context.attacker = BattleContext.SIDE_PLAYER
		context.defender = BattleContext.SIDE_ENEMY
	else:
		context.attacker = BattleContext.SIDE_ENEMY
		context.defender = BattleContext.SIDE_PLAYER

	DebugLogger.info(context.summary(), "Encounter")
	return context


func _snapshot_party(party: Party) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for soldier in state.active_members(party):
		var definition := units.get_definition(soldier.unit_type_id)
		if definition == null:
			DebugLogger.warn("soldier %s has unknown unit type '%s'" % [soldier.full_name(), soldier.unit_type_id], "Encounter")
			continue
		out.append(BattleContext.build_snapshot(soldier, definition, config, traits))
	return out


func _next_battle_counter() -> int:
	var counter := int(state.flags.get("battle_counter", 0)) + 1
	state.flags["battle_counter"] = counter
	return counter


## ---------- retreat ------------------------------------------------------

## Records that the player broke off. The party is pushed away from the enemy and
## left alone for the configured cooldown so the encounter does not immediately
## re-trigger on the next frame.
func apply_retreat(world_party: WorldParty) -> void:
	if world_party == null:
		return
	world_party.encounter_cooldown_until_hours = _now_hours() + cooldown_hours()

	var away := state.world_position - world_party.position
	if away.length() < 0.001:
		away = Vector2.RIGHT
	var push := maxf(trigger_radius() * 2.0, 40.0)
	state.world_position += away.normalized() * push
	state.destination_id = ""
	DebugLogger.info("retreated from %s; they will not trouble you for %.1f hours" % [
		world_party.display_name, cooldown_hours(),
	], "Encounter")
