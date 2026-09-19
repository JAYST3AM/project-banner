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
## The world distinguishes four kinds of settlement; these two are the ones that used to be flattened
## into a town on the way in, which threw away the land's own judgement and left the map unable to
## show a fort as a fort.
const TYPE_FORT := "fort"
const TYPE_CASTLE := "castle"

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
## The last day the party stood inside: the hover card stamps its numbers with it, so stale
## knowledge reads as stale (D-136).
var last_visited_day: int = 0

## Generated detail (D-136), filled by [SettlementDetails]: what stands here, what is traded, which
## houses hold it, how rich and how defended. Empty on a save written before this existed; the world
## map backfills on entry.
var buildings: Array = []
## The ground the settlement stands on (D-138), as the building system reads it: Plains, Forest,
## Highlands, Coastal or Arid. Named, not authored - it is a reading of the world's own sample.
var biome: String = ""
var produces: Array[String] = []
var wants: Array[String] = []
## [{ "id": "house_caldreth", "name": "House Caldreth", "power": 61 }], biggest first, sums to 100.
var families: Array = []
var wealth: String = ""
var garrison: int = 0
## Which generation rules produced the detail above. A save below the current version is regenerated
## on the next map entry (D-136 follow-up: trade must come from the buildings that provide it).
var details_version: int = 0


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
		"last_visited_day": last_visited_day,
		"buildings": buildings.duplicate(true),
		"produces": produces.duplicate(),
		"wants": wants.duplicate(),
		"families": families.duplicate(true),
		"wealth": wealth,
		"garrison": garrison,
		"details_version": details_version,
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
	s.last_visited_day = int(data.get("last_visited_day", 0))
	s.buildings = (data.get("buildings", []) as Array).duplicate(true)
	s.biome = str(data.get("biome", ""))
	var produces_raw: Array = data.get("produces", []) as Array
	for item in produces_raw:
		s.produces.append(str(item))
	var wants_raw: Array = data.get("wants", []) as Array
	for item in wants_raw:
		s.wants.append(str(item))
	s.families = (data.get("families", []) as Array).duplicate(true)
	s.wealth = str(data.get("wealth", ""))
	s.garrison = int(data.get("garrison", 0))
	s.details_version = int(data.get("details_version", 0))
	return s
