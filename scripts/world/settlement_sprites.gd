class_name SettlementSprites
extends RefCounted
## Which structure sprite stands at a settlement (accepted set, 2026-09-19).
##
## Pure lookup, no drawing and no state: a function of the settlement's kind, the ground it sits
## on and its wealth, all of which [SettlementDetails] already decided for this seed. Two runs of
## a seed therefore show the same towns standing in the same buildings - the same rule the rest
## of the map's detail follows.
##
## The ladder the sprites were drawn as, village to stronghold: a longhouse, a manor hall, a town
## hall, a palisade fort, a stone castle, a stronghold - plus a moated castle for the coast and a
## hill citadel for the high ground, so the map does not repeat one silhouette where the land
## changes.

const LONGHOUSE := preload("res://assets/sprites/settlements/struct_1_longhouse.png")
const MANOR_HALL := preload("res://assets/sprites/settlements/struct_2_manor_hall.png")
const TOWN_HALL := preload("res://assets/sprites/settlements/struct_3_town_hall.png")
const PALISADE_FORT := preload("res://assets/sprites/settlements/struct_4_palisade_fort.png")
const STONE_CASTLE := preload("res://assets/sprites/settlements/struct_5_stone_castle.png")
const STRONGHOLD := preload("res://assets/sprites/settlements/struct_6_stronghold.png")
const MOAT_CASTLE := preload("res://assets/sprites/settlements/struct_7_moat_castle.png")
const HILL_CITADEL := preload("res://assets/sprites/settlements/struct_8_hill_citadel.png")


## The sprite for a settled place. Wilderness and anything unknown fall back to the village
## longhouse; the map view draws its own disc for wilderness instead of calling this.
static func texture_for(settlement: Settlement) -> Texture2D:
	match settlement.type:
		Settlement.TYPE_CASTLE:
			# The ground decides a castle's face: the coast wears a moat, the high ground builds
			# on the rock, everywhere else is the stronghold.
			match settlement.biome:
				"Coastal":
					return MOAT_CASTLE
				"Highlands":
					return HILL_CITADEL
			return STRONGHOLD
		Settlement.TYPE_FORT:
			# A fort that can afford stone stops being a palisade.
			return STONE_CASTLE if settlement.wealth == "wealthy" else PALISADE_FORT
		Settlement.TYPE_TOWN:
			return TOWN_HALL
		Settlement.TYPE_VILLAGE:
			return MANOR_HALL if settlement.wealth == "wealthy" else LONGHOUSE
		_:
			return LONGHOUSE


## ---------- scale on the map --------------------------------------------------

## How wide each structure stands on the campaign map, in world units. The map is 4096 units across
## and a settlement must read as a landmark from the default view, so these are deliberately big:
## a village is over a hundred units of ground and a castle nearly two hundred.
const MAP_WIDTH := {
	Settlement.TYPE_VILLAGE: 130.0,
	Settlement.TYPE_TOWN: 160.0,
	Settlement.TYPE_FORT: 160.0,
	Settlement.TYPE_CASTLE: 200.0,
}


## A settlement's map width. Anything unknown gets the village's.
static func map_width(type: String) -> float:
	return float(MAP_WIDTH.get(type, 130.0))


## How far its clearing reaches into the ground around it, in world units. The terrain builders
## carve a clearing to this reach, so the structure stands on flattened, trodden ground and the
## country takes back over past it.
static func clearing_radius(type: String) -> float:
	return map_width(type) * 1.05


## ---------- terrain clearings -------------------------------------------------

## The clearings, bucketed so a terrain builder's per-cell loop only tests the few settlements that
## could possibly reach the cell. [param world] is a WorldChunks - the same source the field is
## sampled from, so the clearing and the country agree.
##
## The land a town stands on is used land: within the inner radius it is flattened to the town's own
## height and worn by feet, carts and smoke; the band out to the outer radius is where the country
## takes back over - the same idea as the looks' blend band, so the town does not stop at a line.
const CLEAR_BUCKET := 256.0


static func clearing_index(settlements: Array, world: RefCounted) -> Dictionary:
	var index: Dictionary = {}
	for settlement_any in settlements:
		var settlement := settlement_any as Settlement
		if settlement == null or settlement.type == Settlement.TYPE_WILDERNESS:
			continue
		var bucket := Vector2i(floori(settlement.position.x / CLEAR_BUCKET),
			floori(settlement.position.y / CLEAR_BUCKET))
		var entry := {
			"position": settlement.position,
			"height": float(world.sample(settlement.position).get("height", 0.5)),
			"inner": map_width(settlement.type) * 0.6,
			"outer": clearing_radius(settlement.type),
		}
		if not index.has(bucket):
			index[bucket] = [] as Array
		(index[bucket] as Array).append(entry)
	return index


## The clearings that could reach [param point], searching its bucket and the eight around it.
static func clearings_at(index: Dictionary, point: Vector2) -> Array:
	if index.is_empty():
		return [] as Array
	var bx := floori(point.x / CLEAR_BUCKET)
	var by := floori(point.y / CLEAR_BUCKET)
	var out: Array = []
	for dx in [-1, 0, 1]:
		for dy in [-1, 0, 1]:
			out.append_array(index.get(Vector2i(bx + dx, by + dy), []))
	return out
