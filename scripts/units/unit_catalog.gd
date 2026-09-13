class_name UnitCatalog
extends RefCounted
## Loads and validates the unit archetypes from [code]data/units/unit_types.json[/code].
##
## Instantiate one, ask it for definitions. Nothing else in the project reads the
## unit JSON directly, so retuning or adding archetypes stays a data-only change.

const UNITS_PATH := "res://data/units/unit_types.json"

var definitions: Dictionary = {}
var load_errors: Array[String] = []


static func load_from(path: String = UNITS_PATH) -> UnitCatalog:
	var catalog := UnitCatalog.new()
	catalog._read(path)
	return catalog


func _read(path: String) -> void:
	definitions.clear()
	load_errors.clear()
	var data := GameData.load_json(path)
	var raw_list := data.get("units", []) as Array
	if raw_list.is_empty():
		load_errors.append("no units found in %s" % path)
	for raw in raw_list:
		if typeof(raw) != TYPE_DICTIONARY:
			load_errors.append("unit entry is not an object")
			continue
		var definition := UnitDefinition.from_dict(raw as Dictionary)
		if definition.id.is_empty():
			load_errors.append("unit entry has no id")
			continue
		if definitions.has(definition.id):
			load_errors.append("duplicate unit id '%s'" % definition.id)
			continue
		definitions[definition.id] = definition
	for message in load_errors:
		DebugLogger.error("unit catalog: %s" % message, "UnitCatalog")
	if not load_errors.is_empty():
		return
	DebugLogger.debug("unit catalog loaded: %d archetypes (%s)" % [
		definitions.size(), ", ".join(definitions.keys()),
	], "UnitCatalog")


func has(unit_type_id: String) -> bool:
	return definitions.has(unit_type_id)


func get_definition(unit_type_id: String) -> UnitDefinition:
	return definitions.get(unit_type_id, null) as UnitDefinition


func ids() -> Array[String]:
	var out: Array[String] = []
	for key in definitions.keys():
		out.append(str(key))
	out.sort()
	return out


func all() -> Array[UnitDefinition]:
	var out: Array[UnitDefinition] = []
	for key in definitions.keys():
		var definition := definitions[key] as UnitDefinition
		if definition != null:
			out.append(definition)
	return out


func display_name(unit_type_id: String) -> String:
	var definition := get_definition(unit_type_id)
	if definition == null:
		return unit_type_id.replace("_", " ").capitalize()
	return definition.display_name


func recruit_cost(unit_type_id: String) -> int:
	var definition := get_definition(unit_type_id)
	if definition == null:
		return 0
	return definition.recruit_cost


## Archetypes seeded into a settlement's starting recruit pool, with counts,
## scaled by settlement population. Used by WorldBuilder when a settlement is
## authored without an explicit pool.
func default_pool_for(population: int) -> Dictionary:
	var pool := {}
	if population < 500:
		pool["peasant_recruit"] = 3
		pool["archer"] = 1
		return pool
	pool["peasant_recruit"] = 7
	pool["spearman"] = 3
	pool["archer"] = 2
	return pool
