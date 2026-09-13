class_name FormationCatalog
extends RefCounted
## The formation shapes, loaded from [code]data/formations/formation_types.json[/code].
##
## A formation type is [i]geometry and movement[/i]: how wide a shape is willing to
## spread, how far apart its soldiers stand, how fast it can turn. Nothing here is a
## combat bonus, and nothing here is hardcoded to a unit type - a future shield wall or
## pike phalanx is another entry in this table plus the mechanics that read it.

const TYPES_PATH := "res://data/formations/formation_types.json"
const FALLBACK_ID := "line"

var types: Dictionary = {}
var order: Array[String] = []
var load_errors: Array[String] = []


static func load_from(path: String = TYPES_PATH) -> FormationCatalog:
	var catalog := FormationCatalog.new()
	catalog._read(path)
	return catalog


func _read(path: String) -> void:
	types.clear()
	order.clear()
	load_errors.clear()
	var data := GameData.load_json(path)
	var raw_list := data.get("formations", []) as Array
	if raw_list.is_empty():
		load_errors.append("no formations found in %s" % path)
	for raw in raw_list:
		if typeof(raw) != TYPE_DICTIONARY:
			load_errors.append("formation entry is not an object")
			continue
		var record := raw as Dictionary
		var id := str(record.get("id", ""))
		if id.is_empty():
			load_errors.append("formation entry has no id")
			continue
		if types.has(id):
			load_errors.append("duplicate formation id '%s'" % id)
			continue
		types[id] = record
		order.append(id)
	for message in load_errors:
		DebugLogger.error("formation catalog: %s" % message, "FormationCatalog")


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


## The widest the shape will spread to. This one number is what makes a line wide and
## a column deep; every other geometric consequence follows from it.
func max_files(id: String) -> int:
	var record := define(id)
	return maxi(1, int(record.get("max_files", 10)))


func spacing_multiplier(id: String) -> float:
	var record := define(id)
	return maxf(0.1, float(record.get("spacing_multiplier", 1.0)))


func turn_rate_deg(id: String) -> float:
	var record := define(id)
	return maxf(1.0, float(record.get("turn_rate_deg", 120.0)))


func move_factor(id: String) -> float:
	var record := define(id)
	return maxf(0.05, float(record.get("move_factor", 1.0)))


func ids() -> Array[String]:
	return order.duplicate()
