class_name SoilCatalog
extends RefCounted
## The soils, loaded from [code]data/terrain/soils.json[/code].
##
## A soil is what a cell is made of; a type ([TerrainCatalog]) is what it does. The catalogue hands
## out the small movement modifier, the moisture a soil is like, and the detail overlay it wears, and
## keeps the JSON out of everything else - exactly as [TerrainCatalog] does for types.

const PATH := "res://data/terrain/soils.json"
const FALLBACK_ID := "grass"

var soils: Dictionary = {}
var order: Array[String] = []
var load_errors: Array[String] = []


static func load_from(path: String = PATH) -> SoilCatalog:
	var catalog := SoilCatalog.new()
	catalog._read(path)
	return catalog


func _read(path: String) -> void:
	soils.clear()
	order.clear()
	load_errors.clear()
	var data := GameData.load_json(path)
	var raw_list := data.get("soils", []) as Array
	if raw_list.is_empty():
		load_errors.append("no soils found in %s" % path)
	for raw in raw_list:
		if typeof(raw) != TYPE_DICTIONARY:
			load_errors.append("soil entry is not an object")
			continue
		var record := raw as Dictionary
		var id := str(record.get("id", ""))
		if id.is_empty():
			load_errors.append("soil entry has no id")
			continue
		if soils.has(id):
			load_errors.append("duplicate soil id '%s'" % id)
			continue
		soils[id] = record
		order.append(id)
	for message in load_errors:
		DebugLogger.error("soil catalog: %s" % message, "SoilCatalog")


func is_valid() -> bool:
	return not soils.is_empty()


func has(id: String) -> bool:
	return soils.has(id)


func define(id: String) -> Dictionary:
	var record: Variant = soils.get(id, null)
	return record as Dictionary if typeof(record) == TYPE_DICTIONARY else {}


func display_name(id: String) -> String:
	var record := define(id)
	return str(record.get("name", id))


## Multiplied onto the type's own multiplier. Keep in mind what this means: a cell's movement
## multiplier is composed once at generation and cached, so nothing here is read per step.
func move_modifier(id: String) -> float:
	var record := define(id)
	return clampf(float(record.get("move_modifier", 1.0)), 0.2, 1.0)


func moisture(id: String) -> float:
	var record := define(id)
	return clampf(float(record.get("moisture", 0.35)), 0.0, 1.0)


func overlay(id: String) -> String:
	var record := define(id)
	return str(record.get("overlay", "none"))


func colour(id: String) -> Color:
	var record := define(id)
	var raw := str(record.get("colour", "4f621a"))
	return Color(raw) if Color.html_is_valid(raw) else Color("4f621a")


func index_of(id: String) -> int:
	return order.find(id)


func id_of(index: int) -> String:
	if index < 0 or index >= order.size():
		return FALLBACK_ID
	return order[index]
