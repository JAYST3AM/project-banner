class_name BattleResolver
extends RefCounted
## Turns a finished battle into consequences.
##
## Two halves, deliberately separate:
## [br]- [method build_result] reads the battle and the campaign and produces a
##   [BattleResult]. It mutates [b]nothing[/b].
## [br]- [method apply] writes that result back: who died, who earned what, the
##   gold, and whether the enemy party still exists.
##
## Nothing in a battle touches campaign data until an outcome has been decided.
## That is what stops a mid-fight crash, a quit-to-menu or a debug exit from
## leaving a soldier half-dead in the save file.

const ITEMS_PATH := "res://data/items/items.json"

var state: CampaignState = null
var config: GameConfig = null

var _items: Array = []


static func build(p_state: CampaignState, p_config: GameConfig) -> BattleResolver:
	if p_state == null or p_config == null:
		return null
	var resolver := BattleResolver.new()
	resolver.state = p_state
	resolver.config = p_config
	resolver._items = (GameData.load_json(ITEMS_PATH).get("items", []) as Array)
	return resolver


## ---------- outcome ------------------------------------------------------

## [param winner_side] is the simulator's verdict, or "" for a draw.
## [param retreated] overrides everything: the player broke off.
func build_result(
	context: BattleContext,
	simulator: BattleSimulator,
	winner_side: String,
	duration: float,
	retreated: bool = false
) -> BattleResult:
	var result := BattleResult.new()
	if context == null:
		return result

	result.battle_id = context.battle_id
	result.enemy_display_name = context.enemy_display_name
	result.duration_seconds = duration
	result.campaign_day = context.campaign_day
	result.campaign_hour = context.campaign_hour

	if retreated:
		result.winner = BattleResult.WINNER_RETREAT
	elif winner_side.is_empty():
		result.winner = BattleResult.WINNER_DRAW
	else:
		result.winner = winner_side

	var victory := result.player_won()
	var location := _nearest_settlement_name(context.world_position)

	for unit in simulator.units:
		if unit.side == BattleContext.SIDE_PLAYER:
			result.player_total += 1
			if unit.is_alive():
				result.player_survivors.append(_survivor_entry(unit, victory))
			else:
				result.player_dead.append(_fallen_entry(unit, simulator, context.enemy_display_name))
		else:
			result.enemy_total += 1
			if not unit.is_alive():
				result.enemy_dead.append(_fallen_entry(unit, simulator, context.enemy_display_name))

	for entry in result.player_survivors:
		result.xp_awarded += int(entry.get("xp_gained", 0))

	if victory:
		_award_spoils(result, context, location)

	DebugLogger.info("%s: %s - %d of %d survived, %d of %d enemies down, %d gold, %d xp" % [
		result.battle_id, result.title(),
		result.player_survivors.size(), result.player_total,
		result.enemy_dead.size(), result.enemy_total,
		result.gold_total(), result.xp_awarded,
	], "Resolver")
	return result


func _survivor_entry(unit: BattleUnit, victory: bool) -> Dictionary:
	var xp := config.get_int("xp.participation", 10)
	xp += config.get_int("xp.per_kill", 20) * unit.kills
	xp += config.get_int("xp.survived_battle", 15)
	if victory:
		xp += config.get_int("xp.victory", 25)
	return {
		"soldier_id": unit.soldier_id,
		"name": unit.display_name,
		"level": unit.level,
		"kills": unit.kills,
		"damage_dealt": unit.damage_dealt,
		"hp": unit.hp,
		"max_hp": unit.max_hp,
		"xp_gained": xp,
		"levels_gained": 0,
		"participated": true,
	}


func _fallen_entry(unit: BattleUnit, simulator: BattleSimulator, enemy_name: String) -> Dictionary:
	var killer_name := ""
	var killer := simulator.find_unit(unit.killed_by_id)
	if killer != null:
		killer_name = killer.display_name
	var note := "Killed at the hands of %s." % killer_name if not killer_name.is_empty() else "Killed in the fighting."
	return {
		"soldier_id": unit.soldier_id,
		"name": unit.display_name,
		"level": unit.level,
		"kills": unit.kills,
		"damage_dealt": unit.damage_dealt,
		"killed_by_id": unit.killed_by_id,
		"killed_by": killer_name,
		"enemy_name": enemy_name,
		"death_note": note,
	}


func _award_spoils(result: BattleResult, context: BattleContext, location: String) -> void:
	# Seeded from the battle, so the same fight always pays the same.
	var generator := RandomNumberGenerator.new()
	generator.seed = context.battle_seed

	var minimum := config.get_int("rewards.gold_per_defeated_min", 8)
	var maximum := config.get_int("rewards.gold_per_defeated_max", 14)
	for i in result.enemy_dead.size():
		result.gold_from_enemies += generator.randi_range(minimum, maximum)
	result.gold_from_victory = config.get_int("rewards.victory_gold_bonus", 25)

	var rolls_min := config.get_int("rewards.loot_rolls_min", 0)
	var rolls_max := config.get_int("rewards.loot_rolls_max", 2)
	var rolls := generator.randi_range(rolls_min, rolls_max)
	for i in rolls:
		var item := _roll_item(generator)
		if item.is_empty():
			continue
		result.loot.append(item)
		result.gold_from_loot += int(item.get("value", 0))

	if result.gold_total() > 0:
		DebugLogger.debug("spoils taken near %s: %d gold, %d items" % [
			location, result.gold_total(), result.loot.size(),
		], "Resolver")


func _roll_item(generator: RandomNumberGenerator) -> Dictionary:
	if _items.is_empty():
		return {}
	var raw: Variant = _items[generator.randi_range(0, _items.size() - 1)]
	if typeof(raw) != TYPE_DICTIONARY:
		return {}
	var record := raw as Dictionary
	return {
		"id": str(record.get("id", "")),
		"name": str(record.get("name", "something")),
		"value": int(record.get("value", 0)),
		"kind": str(record.get("kind", "misc")),
	}


func _nearest_settlement_name(point: Vector2) -> String:
	var best := ""
	var best_distance := INF
	for key in state.settlements.keys():
		var settlement := state.settlements[key] as Settlement
		if settlement == null:
			continue
		var distance := point.distance_to(settlement.position)
		if distance < best_distance:
			best_distance = distance
			best = settlement.name
	return best if not best.is_empty() else "the road"


## ---------- consequences -------------------------------------------------

## Write the result back to the campaign. Everything a battle does to the world
## happens in this one function.
func apply(result: BattleResult, context: BattleContext) -> void:
	if result == null or state == null:
		return
	var day := result.campaign_day
	var location := _nearest_settlement_name(context.world_position) if context != null else "the road"

	for entry in result.player_survivors:
		var soldier := state.soldier(str(entry.get("soldier_id", "")))
		if soldier == null:
			continue
		soldier.battles_fought += 1
		soldier.battles_survived += 1
		soldier.kills += int(entry.get("kills", 0))
		soldier.hp = clampi(int(entry.get("hp", soldier.hp)), 1, soldier.max_hp)
		var levels := soldier.add_xp(int(entry.get("xp_gained", 0)), config)
		entry["levels_gained"] = levels
		if levels > 0:
			_grow_for_levels(soldier, levels)
			soldier.record_history(day, "level", "Reached level %d after the fighting near %s." % [
				soldier.level, location,
			])
		var kills := int(entry.get("kills", 0))
		if kills > 0:
			soldier.record_history(day, "battle", "Killed %d at %s and lived." % [
				kills, location,
			])
		else:
			soldier.record_history(day, "battle", "Fought at %s and lived." % location)

	for entry in result.player_dead:
		var soldier := state.soldier(str(entry.get("soldier_id", "")))
		if soldier == null:
			continue
		soldier.battles_fought += 1
		# A soldier who killed someone before they fell still did so. Losing that
		# would quietly rewrite the record of a fight that actually happened.
		soldier.kills += int(entry.get("kills", 0))
		soldier.hp = 0
		soldier.status = Soldier.STATUS_DEAD
		var note := str(entry.get("death_note", ""))
		soldier.record_history(day, "death", note if not note.is_empty() else "Killed at %s." % location)

	# Enemy dead are their own people; mark them so they are never fielded again.
	for entry in result.enemy_dead:
		var enemy := state.soldier(str(entry.get("soldier_id", "")))
		if enemy == null:
			continue
		enemy.battles_fought += 1
		enemy.hp = 0
		enemy.status = Soldier.STATUS_DEAD

	state.player_gold += result.gold_total()

	var world_party := state.world_party(context.world_party_id) if context != null else null
	if world_party != null:
		var enemy_party := state.party_of(world_party)
		var enemies_left := 0
		if enemy_party != null:
			enemies_left = state.active_members(enemy_party).size()
		if result.player_won() or enemies_left == 0:
			world_party.defeated = true
			DebugLogger.info("%s is destroyed and removed from the map" % world_party.display_name, "Resolver")
		elif result.enemy_won():
			_push_player_clear(world_party)
		else:
			# Draw or withdrawal: nobody holds the field, so give both sides space.
			world_party.encounter_cooldown_until_hours = state.clock.total_hours() + 3.0
			state.destination_id = ""

	state.flags["battle_counter"] = maxi(1, int(state.flags.get("battle_counter", 1)))
	state.flags["battles_fought"] = int(state.flags.get("battles_fought", 0)) + 1
	state.flags["last_battle_id"] = result.battle_id
	state.flags["total_battle_gold"] = int(state.flags.get("total_battle_gold", 0)) + result.gold_total()
	_append_battle_log(result)

	if result.party_wiped():
		DebugLogger.warn("the player's party was wiped out at %s" % location, "Resolver")


## A small, JSON-safe chronicle of the campaign's battles. Kept in the save so the
## world remembers its own history, and so the outcome of a fight can be verified
## afterwards without holding on to a live BattleResult.
func _append_battle_log(result: BattleResult) -> void:
	var log: Array = state.flags.get("battle_log", [])
	log.append({
		"battle_id": result.battle_id,
		"day": result.campaign_day,
		"hour": result.campaign_hour,
		"winner": result.winner,
		"enemy": result.enemy_display_name,
		"player_total": result.player_total,
		"player_survivors": result.player_survivors.size(),
		"player_dead": result.player_dead.size(),
		"enemy_total": result.enemy_total,
		"enemy_dead": result.enemy_dead.size(),
		"gold": result.gold_total(),
		"xp": result.xp_awarded,
		"duration": result.duration_seconds,
		"dead_names": _names_of(result.player_dead),
		"survivor_names": _names_of(result.player_survivors),
	})
	# Bounded, so a very long campaign does not grow the save without limit.
	while log.size() > 40:
		log.pop_front()
	state.flags["battle_log"] = log


func _names_of(entries: Array[Dictionary]) -> Array:
	var out: Array = []
	for entry in entries:
		out.append(str(entry.get("name", "")))
	return out


## The most recent battle summary, or an empty dictionary.
func last_battle_summary() -> Dictionary:
	var log: Array = state.flags.get("battle_log", [])
	if log.is_empty():
		return {}
	var last: Variant = log[log.size() - 1]
	return last as Dictionary if typeof(last) == TYPE_DICTIONARY else {}


func _grow_for_levels(soldier: Soldier, levels: int) -> void:
	var per_level := config.get_int("progression.hp_per_level", 3)
	var gained := per_level * levels
	soldier.max_hp += gained
	soldier.hp = mini(soldier.max_hp, soldier.hp + gained)


func _push_player_clear(world_party: WorldParty) -> void:
	var away := state.world_position - world_party.position
	if away.length() < 0.001:
		away = Vector2.RIGHT
	state.world_position += away.normalized() * 60.0
	state.destination_id = ""
	world_party.encounter_cooldown_until_hours = state.clock.total_hours() + 6.0
