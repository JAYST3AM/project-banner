class_name Settlement
extends RefCounted
## A fixed point of interest on the world map.
##
## Pure data plus derived helpers. Nothing here decides *how* recruitment or
## trade work - those systems read this record and mutate [member recruit_pool] /
## [member market] through their own code, so the settlement stays a passive
## record that is trivial to serialise.

const TYPE_TOWN := "town"
const TYPE_VILLAGE := "village"
const TYPE_WILDERNESS := "wilderness"

var id: String = ""
var name: String = ""
var type: String = TYPE_TOWN
var description: String = ""
var position: Vector2 = Vector2.ZERO
var owner_faction_id: String = ""
var population: int = 0

## unit_type_id -> how many are currently available to recruit here
var recruit_pool: Dictionary = {}
## unit_type_id -> pool size restored each restock
var recruit_pool_base: Dictionary = {}
## Placeholder for the future trade system.
var market: Dictionary = {}

var last_restock_day: int = 1
var visited: bool = false


func is_enterable() -> bool:
	return type != TYPE_WILDERNESS


func type_display() -> String:
	return type.capitalize()


## Restock the recruit pool if enough in-game days have passed.
## Returns true when the pool actually changed.
func restock_if_due(current_day: int, restock_days: int) -> bool:
	if restock_days <= 0:
		return false
	if current_day - last_restock_day < restock_days:
		return false
	last_restock_day = current_day
	for unit_type_id in recruit_pool_base.keys():
		var base: int = int(recruit_pool_base[unit_type_id])
		var current: int = int(recruit_pool.get(unit_type_id, 0))
		recruit_pool[unit_type_id] = maxi(current, base)
	return true


func total_recruits_available() -> int:
	var total := 0
	for key in recruit_pool.keys():
		total += maxi(0, int(recruit_pool[key]))
	return total


func to_dict() -> Dictionary:
	return {
		"id": id,
		"name": name,
		"type": type,
		"description": description,
		"position": [position.x, position.y],
		"owner_faction_id": owner_faction_id,
		"population": population,
		"recruit_pool": recruit_pool.duplicate(true),
		"recruit_pool_base": recruit_pool_base.duplicate(true),
		"market": market.duplicate(true),
		"last_restock_day": last_restock_day,
		"visited": visited,
	}


static func from_dict(data: Dictionary) -> Settlement:
	var s := Settlement.new()
	s.id = str(data.get("id", ""))
	s.name = str(data.get("name", "Unnamed"))
	s.type = str(data.get("type", TYPE_TOWN))
	s.description = str(data.get("description", ""))
	s.position = DataUtils.vec2_from(data.get("position", [0.0, 0.0]))
	s.owner_faction_id = str(data.get("owner_faction_id", ""))
	s.population = int(data.get("population", 0))
	s.recruit_pool = (data.get("recruit_pool", {}) as Dictionary).duplicate(true)
	s.recruit_pool_base = (data.get("recruit_pool_base", {}) as Dictionary).duplicate(true)
	s.market = (data.get("market", {}) as Dictionary).duplicate(true)
	s.last_restock_day = int(data.get("last_restock_day", 1))
	s.visited = bool(data.get("visited", false))
	return s
