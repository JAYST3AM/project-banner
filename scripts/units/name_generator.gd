class_name NameGenerator
extends RefCounted
## Procedural medieval names, driven by the campaign seed.
##
## Names are derived from the campaign seed plus a per-soldier index rather than
## from a live RNG object, so:
## [br]- the same campaign seed produces the same people,
## [br]- names survive a save/load without having to persist generator state, and
## [br]- generating a name never disturbs any other system's random stream.

const NAMES_PATH := "res://data/names/name_pools.json"
const MAX_ATTEMPTS := 24

var rng_service: RngService = null
var first_names: Array[String] = []
var surnames: Array[String] = []
var bynames: Array[String] = []


static func load_from(rng: RngService, path: String = NAMES_PATH) -> NameGenerator:
	var generator := NameGenerator.new()
	generator.rng_service = rng
	var data := GameData.load_json(path)
	generator.first_names = DataUtils.string_array(data.get("first_names", []))
	generator.surnames = DataUtils.string_array(data.get("surnames", []))
	generator.bynames = DataUtils.string_array(data.get("bynames", []))
	if generator.first_names.is_empty():
		DebugLogger.error("name pool has no first names (%s)" % path, "NameGenerator")
		generator.first_names.append("Unnamed")
	return generator


func is_usable() -> bool:
	return rng_service != null and not first_names.is_empty()


## A name for the soldier with the given index. [param taken] is a set of full
## names already in use; duplicates are retried before being accepted.
## Returns {"first_name": String, "surname": String}.
func name_for(index: int, taken: Dictionary) -> Dictionary:
	if not is_usable():
		return {"first_name": "Unnamed", "surname": ""}
	var attempt := 0
	while attempt < MAX_ATTEMPTS:
		var candidate := _roll(index, attempt)
		var full := "%s %s" % [candidate.get("first_name", ""), candidate.get("surname", "")]
		if not taken.has(full.strip_edges()):
			return candidate
		attempt += 1
	# Every pool combination collided (or the pool is tiny). Accept a duplicate
	# rather than refusing to create a soldier at all.
	return _roll(index, MAX_ATTEMPTS)


## Deterministic integer in [min, max] for this soldier index and purpose.
func value_for(index: int, purpose: String, min_value: int, max_value: int) -> int:
	if rng_service == null:
		return min_value
	var generator := rng_service.stream("recruit:%d:%s" % [index, purpose])
	return generator.randi_range(min_value, max_value)


func _roll(index: int, attempt: int) -> Dictionary:
	var generator := rng_service.stream("name:%d:%d" % [index, attempt])
	return {
		"first_name": first_names[generator.randi_range(0, first_names.size() - 1)],
		"surname": surnames[generator.randi_range(0, surnames.size() - 1)] if not surnames.is_empty() else "",
	}


## Reserved for the future veteran display ("Aldric the Ashen").
func byname_for(index: int) -> String:
	if bynames.is_empty() or rng_service == null:
		return ""
	return bynames[rng_service.stream("byname:%d" % index).randi_range(0, bynames.size() - 1)]
