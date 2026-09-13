class_name BattleContext
extends RefCounted
## Everything a battle scene needs, assembled once, before the scene loads.
##
## [b]This is the only channel between the campaign and a battle.[/b] The battle
## scene must never reach into global state to work out which army it is fighting:
## it consumes this object, which carries both rosters as [i]snapshots[/i].
##
## Two consequences worth being explicit about:
## [br]- A snapshot is a copy of stats, but every entry keeps its [code]soldier_id[/code].
##   So the battle knows exactly which person it is moving around the field, while
##   the campaign's soldier record is not being mutated mid-fight.
## [br]- The context is also a [i]record[/i] of the engagement (world position,
##   terrain and battle seeds, campaign time, who attacked whom), which is exactly
##   what a future siege, ambush or scripted battle would also need.

const SIDE_PLAYER := "player"
const SIDE_ENEMY := "enemy"
const KIND_FIELD := "field"

var battle_id: String = ""
var battle_kind: String = KIND_FIELD

var player_party_id: String = ""
var enemy_party_id: String = ""
## The overworld marker this battle came from, so the world can be updated after.
var world_party_id: String = ""

## Snapshots: see build_snapshot(). Ordered as the army deploys.
var player_snapshot: Array[Dictionary] = []
var enemy_snapshot: Array[Dictionary] = []

var enemy_display_name: String = "Enemies"

var world_position: Vector2 = Vector2.ZERO
var terrain_seed: int = 0
var battle_seed: int = 0
var campaign_day: int = 1
var campaign_hour: float = 8.0
var weather: String = "clear"

var attacker: String = SIDE_PLAYER
var defender: String = SIDE_ENEMY


## Builds a snapshot entry for one soldier. Stats are resolved here - including
## trait modifiers - so the battle scene never has to consult a catalog or a
## soldier record to know what a unit does.
static func build_snapshot(soldier: Soldier, definition: UnitDefinition, config: GameConfig, traits: TraitCatalog) -> Dictionary:
	var level := soldier.level
	var attack := definition.attack_at(level, config)
	var move_speed := definition.move_speed
	if traits != null and not soldier.traits.is_empty():
		var attack_pct := traits.total_modifier(soldier.traits, "attack_pct")
		var speed_pct := traits.total_modifier(soldier.traits, "move_speed_pct")
		attack = maxi(1, int(round(float(attack) * (1.0 + attack_pct / 100.0))))
		move_speed = maxf(0.2, move_speed * (1.0 + speed_pct / 100.0))
	return {
		"soldier_id": soldier.id,
		"name": soldier.full_name(),
		"unit_type_id": definition.id,
		"unit_name": definition.display_name,
		"level": level,
		"max_hp": soldier.max_hp,
		"hp": soldier.hp,
		"attack": attack,
		"defence": definition.defence,
		"move_speed": move_speed,
		"attack_range": definition.attack_range,
		"attack_cooldown": definition.attack_cooldown,
		"ranged": definition.ranged,
		"traits": soldier.traits.duplicate(),
	}


func side_snapshot(side: String) -> Array[Dictionary]:
	return player_snapshot if side == SIDE_PLAYER else enemy_snapshot


func enemy_side() -> String:
	return SIDE_ENEMY if attacker == SIDE_PLAYER else SIDE_PLAYER


## Coarse strength figure used by the encounter prompt. Mirrors the campaign's
## party_strength() calculation so the number shown before the battle matches the
## one shown on the world map.
func strength_of(side: String) -> int:
	var total := 0.0
	for entry in side_snapshot(side):
		var hp := float(entry.get("max_hp", 1))
		var level := int(entry.get("level", 1))
		total += hp * (1.0 + 0.15 * float(level - 1))
	return int(round(total))


func attacker_snapshot() -> Array[Dictionary]:
	return side_snapshot(attacker)


func defender_snapshot() -> Array[Dictionary]:
	return side_snapshot(defender)


func unit_count() -> int:
	return player_snapshot.size() + enemy_snapshot.size()


func summary() -> String:
	return "battle %s at %s: %s (%d) vs %s (%d), %s, seed %d" % [
		battle_id,
		"%.0f,%.0f" % [world_position.x, world_position.y],
		attacker, attacker_snapshot().size(),
		defender, defender_snapshot().size(),
		weather, battle_seed,
	]


## ---------- serialisation -------------------------------------------------
## Not persisted by itself, but round-trippable so a battle can be logged,
## replayed or (later) reconstructed from a save mid-fight.

func to_dict() -> Dictionary:
	return {
		"battle_id": battle_id,
		"battle_kind": battle_kind,
		"player_party_id": player_party_id,
		"enemy_party_id": enemy_party_id,
		"world_party_id": world_party_id,
		"player_snapshot": player_snapshot.duplicate(true),
		"enemy_snapshot": enemy_snapshot.duplicate(true),
		"enemy_display_name": enemy_display_name,
		"world_position": DataUtils.vec2_to(world_position),
		"terrain_seed": terrain_seed,
		"battle_seed": battle_seed,
		"campaign_day": campaign_day,
		"campaign_hour": campaign_hour,
		"weather": weather,
		"attacker": attacker,
		"defender": defender,
	}


static func from_dict(data: Dictionary) -> BattleContext:
	var context := BattleContext.new()
	context.battle_id = str(data.get("battle_id", ""))
	context.battle_kind = str(data.get("battle_kind", KIND_FIELD))
	context.player_party_id = str(data.get("player_party_id", ""))
	context.enemy_party_id = str(data.get("enemy_party_id", ""))
	context.world_party_id = str(data.get("world_party_id", ""))
	context.enemy_display_name = str(data.get("enemy_display_name", "Enemies"))
	context.world_position = DataUtils.vec2_from(data.get("world_position", [0.0, 0.0]))
	context.terrain_seed = int(data.get("terrain_seed", 0))
	context.battle_seed = int(data.get("battle_seed", 0))
	context.campaign_day = int(data.get("campaign_day", 1))
	context.campaign_hour = float(data.get("campaign_hour", 8.0))
	context.weather = str(data.get("weather", "clear"))
	context.attacker = str(data.get("attacker", SIDE_PLAYER))
	context.defender = str(data.get("defender", SIDE_ENEMY))
	context.player_snapshot.clear()
	for entry in data.get("player_snapshot", []) as Array:
		if typeof(entry) == TYPE_DICTIONARY:
			context.player_snapshot.append((entry as Dictionary).duplicate(true))
	context.enemy_snapshot.clear()
	for entry in data.get("enemy_snapshot", []) as Array:
		if typeof(entry) == TYPE_DICTIONARY:
			context.enemy_snapshot.append((entry as Dictionary).duplicate(true))
	return context
