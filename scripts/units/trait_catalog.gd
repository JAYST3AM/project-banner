class_name TraitCatalog
extends RefCounted
## Loads soldier traits from [code]data/traits/traits.json[/code].
##
## Note: this file cannot use `trait` as an identifier - it is a reserved
## keyword in GDScript - so records are read into a variable called `record`.

const TRAITS_PATH := "res://data/traits/traits.json"

var definitions: Dictionary = {}


static func load_from(path: String = TRAITS_PATH) -> TraitCatalog:
	var catalog := TraitCatalog.new()
	catalog._read(path)
	return catalog


func _read(path: String) -> void:
	definitions.clear()
	var data := GameData.load_json(path)
	for raw in data.get("traits", []) as Array:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var record := raw as Dictionary
		var id := str(record.get("id", ""))
		if id.is_empty():
			continue
		definitions[id] = record
	DebugLogger.debug("trait catalog loaded: %d traits" % definitions.size(), "TraitCatalog")


func has(trait_id: String) -> bool:
	return definitions.has(trait_id)


func _record(trait_id: String) -> Dictionary:
	var found: Variant = definitions.get(trait_id, null)
	if typeof(found) == TYPE_DICTIONARY:
		return found as Dictionary
	return {}


## Display name for a trait id, falling back to a title-cased id.
func display_name(trait_id: String) -> String:
	return str(_record(trait_id).get("name", trait_id.replace("_", " ").capitalize()))


func description(trait_id: String) -> String:
	return str(_record(trait_id).get("description", ""))


func modifiers(trait_id: String) -> Dictionary:
	return _record(trait_id).get("modifiers", {}) as Dictionary


func polarity_of(trait_id: String) -> String:
	return str(_record(trait_id).get("polarity", "neutral"))


func ids_with_polarity(wanted_polarity: String) -> Array[String]:
	var out: Array[String] = []
	for key in definitions.keys():
		if polarity_of(str(key)) == wanted_polarity:
			out.append(str(key))
	out.sort()
	return out


func all_ids() -> Array[String]:
	var out: Array[String] = []
	for key in definitions.keys():
		out.append(str(key))
	out.sort()
	return out


## Total of one modifier key across a list of trait ids. Used for morale, loyalty
## and hp_pct at recruitment, and by the battle system for attack_pct and
## move_speed_pct when a fighting unit is built from a soldier.
func total_modifier(trait_ids: Array[String], key: String) -> float:
	var total := 0.0
	for trait_id in trait_ids:
		total += float(modifiers(trait_id).get(key, 0.0))
	return total
