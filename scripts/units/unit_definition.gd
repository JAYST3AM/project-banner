class_name UnitDefinition
extends RefCounted
## A class of soldier (Peasant Recruit, Spearman, Archer, ...).
##
## Definitions come from [code]data/units/unit_types.json[/code]. A definition
## describes what the archetype *is*; a [Soldier] is a specific person of that
## archetype with their own level, wounds and history.

var id: String = ""
var display_name: String = ""
var description: String = ""

var hp: int = 10
var attack: int = 1
var defence: int = 0
var move_speed: float = 5.0
var attack_range: float = 1.0
var attack_cooldown: float = 1.0
var ranged: bool = false

var recruit_cost: int = 0
var upgrade_to: String = ""
## Relative likelihood of appearing in a settlement's recruit pool (reserved).
var recruit_weight: int = 1


static func from_dict(data: Dictionary) -> UnitDefinition:
	var d := UnitDefinition.new()
	d.id = str(data.get("id", ""))
	d.display_name = str(data.get("name", d.id))
	d.description = str(data.get("description", ""))
	d.hp = maxi(1, int(data.get("hp", 10)))
	d.attack = maxi(0, int(data.get("attack", 1)))
	d.defence = maxi(0, int(data.get("defence", 0)))
	d.move_speed = maxf(0.1, float(data.get("move_speed", 5.0)))
	d.attack_range = maxf(0.1, float(data.get("attack_range", 1.0)))
	d.attack_cooldown = maxf(0.05, float(data.get("attack_cooldown", 1.0)))
	d.ranged = bool(data.get("ranged", false))
	d.recruit_cost = maxi(0, int(data.get("recruit_cost", 0)))
	d.upgrade_to = str(data.get("upgrade_to", ""))
	d.recruit_weight = maxi(0, int(data.get("recruit_weight", 1)))
	return d


func to_dict() -> Dictionary:
	return {
		"id": id,
		"name": display_name,
		"description": description,
		"hp": hp,
		"attack": attack,
		"defence": defence,
		"move_speed": move_speed,
		"attack_range": attack_range,
		"attack_cooldown": attack_cooldown,
		"ranged": ranged,
		"recruit_cost": recruit_cost,
		"upgrade_to": upgrade_to,
		"recruit_weight": recruit_weight,
	}


## Effective maximum hit points for a soldier of this archetype at a given level.
## This is the single place the progression curve is applied to hit points.
func max_hp_at(level: int, config: GameConfig) -> int:
	var per_level := config.get_int("progression.hp_per_level", 3) if config != null else 3
	return hp + (maxi(1, level) - 1) * per_level


func attack_at(level: int, config: GameConfig) -> int:
	var per_level := config.get_int("progression.attack_per_level", 1) if config != null else 1
	return attack + (maxi(1, level) - 1) * per_level
