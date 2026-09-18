class_name BiomeCatalog
extends RefCounted
## The biomes, loaded from [code]data/terrain/biomes.json[/code].
##
## Same shape as [TerrainCatalog] and [UnitCatalog]: instantiate one, ask it questions, and let
## nothing else in the project read the biome JSON directly. A biome is a *country* - its looks, its
## palette, how its land lies and what grows on it - and everything the field generator reads about
## one lives in its [code]terrain[/code] block. Adding a biome is a block in that file: no code here
## knows the name of any particular biome, and nothing in the generator branches on one.
##
## The catalogue is deliberately forgiving. A biome with a missing block, a missing number or no art
## at all still loads and still generates: the fallbacks below are what make "add another biome" a
## data change rather than a debugging session.

const PATH := "res://data/terrain/biomes.json"
## What a field is grown as when nothing says otherwise. The first biome in the file is the fallback
## of last resort.
const FALLBACK_ID := "plains"

var biomes: Dictionary = {}
## Declaration order, so generation and debug output are stable.
var order: Array[String] = []
## The shared prop table: a tree is a tree in any biome, and a biome tunes its density.
var prop_kinds: Dictionary = {}
var load_errors: Array[String] = []


static func load_from(path: String = PATH) -> BiomeCatalog:
	var catalog := BiomeCatalog.new()
	catalog._read(path)
	return catalog


func _read(path: String) -> void:
	biomes.clear()
	order.clear()
	prop_kinds.clear()
	load_errors.clear()
	var data := GameData.load_json(path)
	for raw in data.get("prop_kinds", []) as Array:
		if typeof(raw) != TYPE_DICTIONARY:
			load_errors.append("prop kind entry is not an object")
			continue
		var kind := raw as Dictionary
		var kind_id := str(kind.get("id", ""))
		if kind_id.is_empty():
			load_errors.append("prop kind has no id")
			continue
		prop_kinds[kind_id] = kind
	var raw_biomes := data.get("biomes", []) as Array
	if raw_biomes.is_empty():
		load_errors.append("no biomes found in %s" % path)
	for raw in raw_biomes:
		if typeof(raw) != TYPE_DICTIONARY:
			load_errors.append("biome entry is not an object")
			continue
		var record := raw as Dictionary
		var id := str(record.get("id", ""))
		if id.is_empty():
			load_errors.append("biome entry has no id")
			continue
		if biomes.has(id):
			load_errors.append("duplicate biome id '%s'" % id)
			continue
		biomes[id] = record
		order.append(id)
	for message in load_errors:
		DebugLogger.error("biome catalog: %s" % message, "BiomeCatalog")


func is_valid() -> bool:
	return not biomes.is_empty()


func has(id: String) -> bool:
	return biomes.has(id)


func define(id: String) -> Dictionary:
	var record: Variant = biomes.get(id, null)
	return record as Dictionary if typeof(record) == TYPE_DICTIONARY else {}


## The id to actually use: the one asked for if it exists, the declared fallback, and failing that
## whatever the file does have. Never returns "" on a valid catalogue, so a caller cannot end up
## generating a battlefield out of nothing.
func resolve_id(id: String) -> String:
	if biomes.has(id):
		return id
	if biomes.has(FALLBACK_ID):
		return FALLBACK_ID
	if not order.is_empty():
		return order[0]
	return ""


func display_name(id: String) -> String:
	var record := define(resolve_id(id))
	return str(record.get("name", id))


## The movement rule this biome's ground follows - a [TerrainCatalog] id.
func type_id(id: String) -> String:
	var record := define(resolve_id(id))
	return str(record.get("type", TerrainCatalog.FALLBACK_ID))


## ---------- the battlefield generation block -----------------------------

func terrain_block(id: String) -> Dictionary:
	var record := define(resolve_id(id))
	var block: Variant = record.get("terrain", {})
	return block as Dictionary if typeof(block) == TYPE_DICTIONARY else {}


func elevation_block(id: String) -> Dictionary:
	var block: Variant = terrain_block(id).get("elevation", {})
	return block as Dictionary if typeof(block) == TYPE_DICTIONARY else {}


func features_block(id: String) -> Dictionary:
	var block: Variant = terrain_block(id).get("features", {})
	return block as Dictionary if typeof(block) == TYPE_DICTIONARY else {}


func vegetation_block(id: String) -> Dictionary:
	var block: Variant = terrain_block(id).get("vegetation", {})
	return block as Dictionary if typeof(block) == TYPE_DICTIONARY else {}


func movement_block(id: String) -> Dictionary:
	var block: Variant = terrain_block(id).get("movement", {})
	return block as Dictionary if typeof(block) == TYPE_DICTIONARY else {}


## Numeric read with a default, so a biome that omits a knob still generates.
func number(id: String, key: String, fallback: float, block: String = "terrain") -> float:
	var source := terrain_block(id) if block == "terrain" else {}
	if block == "elevation":
		source = elevation_block(id)
	elif block == "features":
		source = features_block(id)
	elif block == "vegetation":
		source = vegetation_block(id)
	elif block == "movement":
		source = movement_block(id)
	var value: Variant = source.get(key, null)
	if value == null:
		return fallback
	return float(value)


## ---------- looks and art ------------------------------------------------

## The biome's four battlefield ground variants. Each is
## [code]{name, dominant, shader, art: Array[String]}[/code]; art may be empty, and then the variant
## draws as its dominant colour rather than not at all.
func variants(id: String) -> Array:
	var block := terrain_block(id)
	var raw: Variant = block.get("variants", [])
	return raw as Array if typeof(raw) == TYPE_ARRAY else []


func variant_count(id: String) -> int:
	return maxi(1, variants(id).size())


func variant(id: String, index: int) -> Dictionary:
	var list := variants(id)
	if list.is_empty():
		return {}
	var wrapped := posmod(index, list.size())
	var entry: Variant = list[wrapped]
	return entry as Dictionary if typeof(entry) == TYPE_DICTIONARY else {}


func variant_name(id: String, index: int) -> String:
	return str(variant(id, index).get("name", "variant %d" % index))


func variant_colour(id: String, index: int) -> Color:
	var raw := str(variant(id, index).get("dominant", "4f621a"))
	return Color(raw) if Color.html_is_valid(raw) else Color("4f621a")


func variant_art(id: String, index: int) -> Array[String]:
	var list: Variant = variant(id, index).get("art", [])
	if typeof(list) != TYPE_ARRAY:
		return []
	var out: Array[String] = []
	for entry in list as Array:
		out.append(str(entry))
	return out


## The biome's detail overlays, up to four: the first three become the ground shader's RGB channels
## and the fourth its alpha.
func overlays(id: String) -> Array:
	var block := terrain_block(id)
	var raw: Variant = block.get("overlays", [])
	if typeof(raw) != TYPE_ARRAY:
		return []
	var out: Array = []
	for entry in raw as Array:
		if typeof(entry) == TYPE_DICTIONARY:
			out.append(entry)
		if out.size() >= 4:
			break
	return out


func overlay_count(id: String) -> int:
	return overlays(id).size()


func overlay_id(id: String, index: int) -> String:
	var list := overlays(id)
	if index < 0 or index >= list.size():
		return ""
	var entry := list[index] as Dictionary
	return str(entry.get("id", ""))


## ---------- props ---------------------------------------------------------

## Which prop kinds this biome grows, each entry
## [code]{kind, density, min_weight, max_slope, allow_wet}[/code].
func props(id: String) -> Array:
	var block := terrain_block(id)
	var raw: Variant = block.get("props", [])
	if typeof(raw) != TYPE_ARRAY:
		return []
	var out: Array = []
	for entry in raw as Array:
		if typeof(entry) == TYPE_DICTIONARY:
			var record := entry as Dictionary
			if prop_kinds.has(str(record.get("kind", ""))):
				out.append(record)
	return out


## The shared definition of a prop kind: art, size, and what it does to a battle.
func prop_kind(kind_id: String) -> Dictionary:
	var record: Variant = prop_kinds.get(kind_id, null)
	return record as Dictionary if typeof(record) == TYPE_DICTIONARY else {}


func prop_kind_ids() -> Array[String]:
	var out: Array[String] = []
	for key in prop_kinds.keys():
		out.append(str(key))
	out.sort()
	return out


## ---------- soils --------------------------------------------------------

## The soils this biome may choose from, with their weights.
func soils(id: String) -> Array:
	var block := terrain_block(id)
	var raw: Variant = block.get("soils", [])
	if typeof(raw) != TYPE_ARRAY:
		return []
	var out: Array = []
	for entry in raw as Array:
		if typeof(entry) == TYPE_DICTIONARY:
			out.append(entry)
	return out


func summary(id: String) -> String:
	var real := resolve_id(id)
	if real.is_empty():
		return "biome: none"
	return "biome %s: type %s, %d variants, %d overlays, %d props" % [
		real, type_id(real), variant_count(real), overlay_count(real), props(real).size(),
	]
