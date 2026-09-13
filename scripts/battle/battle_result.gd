class_name BattleResult
extends RefCounted
## What a battle produced, in full, before anything is written back to the
## campaign.
##
## A [BattleResult] is a plain description: who won, who is dead, who survived,
## what each survivor earned, and what was taken. [BattleResolver] is what decides
## to apply it. Splitting them means the outcome of a fight can be computed,
## inspected, tested and displayed without ever having mutated a single soldier -
## which is the brief's "controlled battle-result process".

const WINNER_PLAYER := "player"
const WINNER_ENEMY := "enemy"
const WINNER_DRAW := "draw"
## The player broke off: the enemy holds the field, but nobody was routed.
const WINNER_RETREAT := "retreat"

var battle_id: String = ""
var winner: String = WINNER_DRAW
var enemy_display_name: String = "Enemies"

var duration_seconds: float = 0.0
var campaign_day: int = 1
var campaign_hour: float = 8.0

## Survivors, in the order they deployed.
## {"soldier_id", "name", "level", "kills", "damage_dealt", "hp", "max_hp",
##  "xp_gained", "levels_gained", "participated"}
var player_survivors: Array[Dictionary] = []
## The fallen. {"soldier_id", "name", "level", "kills", "killed_by"}
var player_dead: Array[Dictionary] = []
## Enemy soldiers put out of action by the player's party.
var enemy_dead: Array[Dictionary] = []

var enemy_total: int = 0
var player_total: int = 0

var gold_from_enemies: int = 0
var gold_from_loot: int = 0
var gold_from_victory: int = 0
## Looted items, already sold for coin. {"id", "name", "value"}
var loot: Array[Dictionary] = []

var xp_awarded: int = 0


func player_won() -> bool:
	return winner == WINNER_PLAYER


func enemy_won() -> bool:
	return winner == WINNER_ENEMY


func title() -> String:
	match winner:
		WINNER_PLAYER:
			return "VICTORY"
		WINNER_ENEMY:
			return "DEFEAT"
		WINNER_RETREAT:
			return "WITHDREW"
		_:
			return "DRAW"


func gold_total() -> int:
	return gold_from_enemies + gold_from_loot + gold_from_victory


func player_casualties() -> int:
	return player_dead.size()


func total_player_kills() -> int:
	var kills := 0
	for entry in player_survivors:
		kills += int(entry.get("kills", 0))
	for entry in player_dead:
		kills += int(entry.get("kills", 0))
	return kills


## True when the player's party no longer exists.
func party_wiped() -> bool:
	return player_total > 0 and player_survivors.is_empty()


func duration_string() -> String:
	var total := int(round(duration_seconds))
	return "%d:%02d" % [total / 60, total % 60]


## Plain-language one-liner for the results screen header.
func headline() -> String:
	match winner:
		WINNER_PLAYER:
			return "%s defeated: %d" % [enemy_display_name, enemy_dead.size()]
		WINNER_ENEMY:
			return "Your party was broken at %s." % enemy_display_name
		WINNER_RETREAT:
			return "You broke off from %s." % enemy_display_name
		_:
			return "Neither side could break the other."


func to_dict() -> Dictionary:
	return {
		"battle_id": battle_id,
		"winner": winner,
		"enemy_display_name": enemy_display_name,
		"duration_seconds": duration_seconds,
		"campaign_day": campaign_day,
		"campaign_hour": campaign_hour,
		"player_survivors": player_survivors.duplicate(true),
		"player_dead": player_dead.duplicate(true),
		"enemy_dead": enemy_dead.duplicate(true),
		"enemy_total": enemy_total,
		"player_total": player_total,
		"gold_from_enemies": gold_from_enemies,
		"gold_from_loot": gold_from_loot,
		"gold_from_victory": gold_from_victory,
		"loot": loot.duplicate(true),
		"xp_awarded": xp_awarded,
	}


static func from_dict(data: Dictionary) -> BattleResult:
	var result := BattleResult.new()
	result.battle_id = str(data.get("battle_id", ""))
	result.winner = str(data.get("winner", WINNER_DRAW))
	result.enemy_display_name = str(data.get("enemy_display_name", "Enemies"))
	result.duration_seconds = float(data.get("duration_seconds", 0.0))
	result.campaign_day = int(data.get("campaign_day", 1))
	result.campaign_hour = float(data.get("campaign_hour", 8.0))
	result.enemy_total = int(data.get("enemy_total", 0))
	result.player_total = int(data.get("player_total", 0))
	result.gold_from_enemies = int(data.get("gold_from_enemies", 0))
	result.gold_from_loot = int(data.get("gold_from_loot", 0))
	result.gold_from_victory = int(data.get("gold_from_victory", 0))
	result.xp_awarded = int(data.get("xp_awarded", 0))
	result.player_survivors = _dict_array(data.get("player_survivors", []))
	result.player_dead = _dict_array(data.get("player_dead", []))
	result.enemy_dead = _dict_array(data.get("enemy_dead", []))
	result.loot = _dict_array(data.get("loot", []))
	return result


static func _dict_array(raw: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if typeof(raw) != TYPE_ARRAY:
		return out
	for entry in raw as Array:
		if typeof(entry) == TYPE_DICTIONARY:
			out.append((entry as Dictionary).duplicate(true))
	return out
