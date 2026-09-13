extends Node
## GameData (autoload).
##
## The single place gameplay-balance and content data enter the running game.
## Everything under [code]res://data/[/code] is JSON, loaded here once and cached,
## so designers can retune the game without touching a script.

const CONFIG_PATH := "res://data/config/game_config.json"

var config: GameConfig = null

var _cache: Dictionary = {}


func _ready() -> void:
	reload()


func reload() -> void:
	_cache.clear()
	config = GameConfig.load_from(CONFIG_PATH)
	if config.is_valid():
		DebugLogger.info("config loaded from %s (v%s)" % [
			CONFIG_PATH, config.get_value("config_version", "?"),
		], "GameData")
	else:
		DebugLogger.error("config failed: %s" % config.load_error, "GameData")


## Load (and cache) a JSON document. Returns an empty dictionary on failure so
## callers degrade instead of crashing.
func load_json(path: String) -> Dictionary:
	if _cache.has(path):
		return _cache[path] as Dictionary
	var result := {}
	if not FileAccess.file_exists(path):
		DebugLogger.warn("data file missing: %s" % path, "GameData")
		_cache[path] = result
		return result
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		DebugLogger.error("data file is not a JSON object: %s" % path, "GameData")
		_cache[path] = result
		return result
	result = parsed as Dictionary
	_cache[path] = result
	return result
