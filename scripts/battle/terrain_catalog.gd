class_name TerrainCatalog
extends RefCounted
## The battlefield terrain types, loaded from [code]data/terrain/terrain_types.json[/code].
##
## Same shape as [UnitCatalog]: instantiate one, ask it questions, and let nothing
## else in the project read the terrain JSON directly. Adding a terrain type is a
## data change, not a code change.

const TYPES_PATH := "res://data/terrain/terrain_types.json"
## What a position outside the field is treated as, and the fallback when the file
## is missing or malformed.
const FALLBACK_ID := "open"

var types: Dictionary = {}
## Declaration order, so generation and debug output are stable.
var order: Array[String] = []
var load_errors: Array[String] = []


static func load_from(path: String = TYPES_PATH) -> TerrainCatalog:
	var catalog := TerrainCatalog.new()
	catalog._read(path)
	return catalog


func _read(path: String) -> void:
	types.clear()
	order.clear()
	load_errors.clear()
	var data := GameData.load_json(path)
	var raw_list := data.get("terrain_types", []) as Array
	if raw_list.is_empty():
		load_errors.append("no terrain types found in %s" % path)
	for raw in raw_list:
		if typeof(raw) != TYPE_DICTIONARY:
			load_errors.append("terrain entry is not an object")
			continue
		var record := raw as Dictionary
		var id := str(record.get("id", ""))
		if id.is_empty():
			load_errors.append("terrain entry has no id")
			continue
		if types.has(id):
			load_errors.append("duplicate terrain id '%s'" % id)
			continue
		types[id] = record
		order.append(id)
	for message in load_errors:
		DebugLogger.error("terrain catalog: %s" % message, "TerrainCatalog")


func is_valid() -> bool:
	return not types.is_empty()


func has(id: String) -> bool:
	return types.has(id)


func define(id: String) -> Dictionary:
	var record: Variant = types.get(id, null)
	return record as Dictionary if typeof(record) == TYPE_DICTIONARY else {}


func display_name(id: String) -> String:
	var record := define(id)
	return str(record.get("name", id))


## How much of a unit's speed survives moving through this terrain. 1.0 is no
## penalty at all.
func move_multiplier(id: String) -> float:
	var record := define(id)
	return maxf(0.05, float(record.get("move_multiplier", 1.0)))


## Debug/draw colour. The renderer asks for this; the simulation never does.
func colour(id: String) -> Color:
	var record := define(id)
	var raw := str(record.get("colour", "3f4a33"))
	return Color(raw) if Color.html_is_valid(raw) else Color("3f4a33")


## Index of a type in declaration order - what the per-cell arrays store, so a cell
## costs one integer rather than a string.
func index_of(id: String) -> int:
	return order.find(id)


func id_of(index: int) -> String:
	if index < 0 or index >= order.size():
		return FALLBACK_ID
	return order[index]
