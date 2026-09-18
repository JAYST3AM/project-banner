class_name GameConfig
extends RefCounted
## Typed, read-only view over a JSON configuration document.
##
## Gameplay code never hardcodes a tuning number: it asks the config for it by
## dotted path, so rebalancing is a data edit rather than a code edit.
##
## [codeblock]
## var cfg := GameConfig.load_from("res://data/config/game_config.json")
## cfg.get_value("xp.per_kill", 20)      # -> 20
## cfg.get_value("travel.nope", 5.0)     # -> 5.0 (missing paths fall back)
## [/codeblock]
##
## Missing paths always fall back to the caller-supplied default instead of
## erroring, which is what makes old save files and partially-authored config
## files safe to load.

const DEFAULT_CONFIG_PATH := "res://data/config/game_config.json"

var source_path: String = DEFAULT_CONFIG_PATH
var load_error: String = ""

var _data: Dictionary = {}


static func load_from(path: String) -> GameConfig:
	var cfg := GameConfig.new()
	cfg.source_path = path
	if not FileAccess.file_exists(path):
		cfg.load_error = "config file not found: %s" % path
		push_error(cfg.load_error)
		return cfg
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		cfg.load_error = "config file is not a JSON object: %s" % path
		push_error(cfg.load_error)
		return cfg
	cfg._data = parsed
	return cfg


func is_valid() -> bool:
	return load_error.is_empty()


func get_value(path: String, default_value: Variant = null) -> Variant:
	var node: Variant = _data
	for part in path.split("."):
		if typeof(node) != TYPE_DICTIONARY or not (node as Dictionary).has(part):
			return default_value
		node = (node as Dictionary)[part]
	return node


## Override a value at runtime, by the same dotted path the getters take. Tests and dev flags need
## this: the game generates its world, while the suites assert about a known one, and a fixture is
## cheaper than rewriting twenty-eight suites around a generator.
func set_value(path: String, value: Variant) -> void:
	var parts := path.split(".")
	var node: Dictionary = _data
	for i in range(parts.size() - 1):
		var key := parts[i]
		if not node.has(key) or typeof(node[key]) != TYPE_DICTIONARY:
			node[key] = {}
		node = node[key] as Dictionary
	node[parts[parts.size() - 1]] = value


func get_float(path: String, default_value: float = 0.0) -> float:
	return float(get_value(path, default_value))


func get_int(path: String, default_value: int = 0) -> int:
	return int(get_value(path, default_value))


func get_bool(path: String, default_value: bool = false) -> bool:
	return bool(get_value(path, default_value))


func get_string(path: String, default_value: String = "") -> String:
	var v: Variant = get_value(path, default_value)
	return str(v)


func get_dict(path: String, default_value: Dictionary = {}) -> Dictionary:
	var v: Variant = get_value(path, default_value)
	if typeof(v) == TYPE_DICTIONARY:
		return v as Dictionary
	return default_value


func get_array(path: String, default_value: Array = []) -> Array:
	var v: Variant = get_value(path, default_value)
	if typeof(v) == TYPE_ARRAY:
		return v as Array
	return default_value


func section(name: String) -> Dictionary:
	return get_dict(name, {})


func to_dict() -> Dictionary:
	return _data.duplicate(true)
