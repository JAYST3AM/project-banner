class_name Soldier
extends RefCounted
## A single, persistent person in the world.
##
## [Soldier] instances are the *only* place a person's identity lives. Battle
## scenes, roster screens and the world map all hold the same object (or its id)
## and never keep a private copy, so a soldier that survives a battle is the
## same soldier the player recruited twenty in-game days earlier.
##
## Everything a soldier will eventually need (traits, loyalty, a personal
## history log) exists from the first version, because retro-fitting identity
## onto a disposable unit later is the exact failure mode this project avoids.

const STATUS_ACTIVE := "active"
const STATUS_WOUNDED := "wounded"
const STATUS_DEAD := "dead"
const STATUS_RETIRED := "retired"

const STATUS_NAMES := {
	STATUS_ACTIVE: "Active",
	STATUS_WOUNDED: "Wounded",
	STATUS_DEAD: "Dead",
	STATUS_RETIRED: "Retired",
}

var id: String = ""
var first_name: String = ""
var surname: String = ""
var age: int = 20
var unit_type_id: String = ""
var faction_id: String = ""

var level: int = 1
var xp: int = 0
var hp: int = 1
var max_hp: int = 1

var kills: int = 0
var battles_fought: int = 0
var battles_survived: int = 0

var morale: int = 60
var loyalty: int = 50

var traits: Array[String] = []
var status: String = STATUS_ACTIVE

## Chronological personal history: {"day": int, "type": String, "text": String}.
## This is what turns a stat block into someone the player remembers.
var history: Array[Dictionary] = []

## Reserved for equipment/inventory work (post-checkpoint).
var equipment: Dictionary = {}


func full_name() -> String:
	if surname.is_empty():
		return first_name
	return "%s %s" % [first_name, surname]


func is_alive() -> bool:
	return status != STATUS_DEAD


func is_active() -> bool:
	return status == STATUS_ACTIVE or status == STATUS_WOUNDED


func status_display() -> String:
	return str(STATUS_NAMES.get(status, status))


func hp_ratio() -> float:
	if max_hp <= 0:
		return 0.0
	return clampf(float(hp) / float(max_hp), 0.0, 1.0)


## XP required to reach the next level. Curve: base * growth^(level-1).
func xp_to_next(config: GameConfig) -> int:
	var base := 100.0
	var growth := 1.35
	if config != null:
		base = config.get_float("xp.level_curve_base", 100.0)
		growth = config.get_float("xp.level_curve_growth", 1.35)
	var needed: float = base * pow(growth, float(level - 1))
	return maxi(1, int(round(needed)))


## Award XP and level up as far as the total allows.
## Returns the number of levels gained.
func add_xp(amount: int, config: GameConfig) -> int:
	var levels_gained := 0
	if amount <= 0:
		return 0
	xp += amount
	var max_level: int = config.get_int("xp.max_level", 40) if config != null else 40
	while level < max_level and xp >= xp_to_next(config):
		xp -= xp_to_next(config)
		level += 1
		levels_gained += 1
	return levels_gained


func record_history(day: int, type: String, text: String) -> void:
	history.append({"day": day, "type": type, "text": text})


func add_trait(trait_id: String) -> void:
	if not traits.has(trait_id):
		traits.append(trait_id)


func to_dict() -> Dictionary:
	return {
		"id": id,
		"first_name": first_name,
		"surname": surname,
		"age": age,
		"unit_type_id": unit_type_id,
		"faction_id": faction_id,
		"level": level,
		"xp": xp,
		"hp": hp,
		"max_hp": max_hp,
		"kills": kills,
		"battles_fought": battles_fought,
		"battles_survived": battles_survived,
		"morale": morale,
		"loyalty": loyalty,
		"traits": traits.duplicate(),
		"status": status,
		"history": history.duplicate(true),
		"equipment": equipment.duplicate(true),
	}


static func from_dict(data: Dictionary) -> Soldier:
	var s := Soldier.new()
	s.id = str(data.get("id", ""))
	s.first_name = str(data.get("first_name", "Unnamed"))
	s.surname = str(data.get("surname", ""))
	s.age = int(data.get("age", 20))
	s.unit_type_id = str(data.get("unit_type_id", ""))
	s.faction_id = str(data.get("faction_id", ""))
	s.level = maxi(1, int(data.get("level", 1)))
	s.xp = maxi(0, int(data.get("xp", 0)))
	s.max_hp = maxi(1, int(data.get("max_hp", 1)))
	s.hp = clampi(int(data.get("hp", s.max_hp)), 0, s.max_hp)
	s.kills = maxi(0, int(data.get("kills", 0)))
	s.battles_fought = maxi(0, int(data.get("battles_fought", 0)))
	s.battles_survived = maxi(0, int(data.get("battles_survived", 0)))
	s.morale = clampi(int(data.get("morale", 60)), 0, 100)
	s.loyalty = clampi(int(data.get("loyalty", 50)), 0, 100)
	s.status = str(data.get("status", STATUS_ACTIVE))
	s.traits.clear()
	for t in data.get("traits", []):
		s.traits.append(str(t))
	s.history.clear()
	for h in data.get("history", []):
		if typeof(h) == TYPE_DICTIONARY:
			s.history.append(h as Dictionary)
	s.equipment = (data.get("equipment", {}) as Dictionary).duplicate(true)
	return s
