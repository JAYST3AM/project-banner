extends Node
## SaveManager (autoload).
##
## Saves are plain, indented JSON on purpose: a save file that can be read and
## hand-edited is worth far more during prototype development than a compact
## binary blob. The file carries a [code]save_version[/code] so future shape
## changes can be migrated instead of abandoned.

signal save_written(slot: int, path: String)
signal save_failed(slot: int, reason: String)

const SAVE_DIR := "user://saves"
const SLOT_DEFAULT := 1
const SAVE_VERSION := 1

## Migration hooks, keyed by the version they upgrade FROM.
## e.g. MIGRATIONS[1] upgrades a v1 document to v2.
const MIGRATIONS := {}


func slot_path(slot: int = SLOT_DEFAULT) -> String:
	return "%s/slot_%d.save" % [SAVE_DIR, slot]


func ensure_dir() -> bool:
	var err := DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	return err == OK or err == ERR_ALREADY_EXISTS


func has_save(slot: int = SLOT_DEFAULT) -> bool:
	return FileAccess.file_exists(slot_path(slot))


## Lightweight read used by the main menu; never builds a CampaignState.
func peek_metadata(slot: int = SLOT_DEFAULT) -> Dictionary:
	if not has_save(slot):
		return {}
	var text := FileAccess.get_file_as_string(slot_path(slot))
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var data := parsed as Dictionary
	var clock_data := data.get("clock", {}) as Dictionary
	return {
		"campaign_name": str(data.get("campaign_name", "Unnamed Campaign")),
		"campaign_seed": int(data.get("campaign_seed", 0)),
		"day": int(clock_data.get("day", 1)),
		"hour": float(clock_data.get("hour", 8.0)),
		"player_gold": int(data.get("player_gold", 0)),
		"party_size": ((data.get("player_party", {}) as Dictionary).get("member_ids", []) as Array).size(),
		"save_version": int(data.get("save_version", 0)),
		"saved_at": str(data.get("last_saved_at", "")),
	}


func save_campaign(state: CampaignState, slot: int = SLOT_DEFAULT) -> bool:
	if state == null:
		save_failed.emit(slot, "no campaign state")
		return false
	if not ensure_dir():
		save_failed.emit(slot, "could not create %s" % SAVE_DIR)
		return false

	state.last_saved_at = Time.get_datetime_string_from_system(false, true)
	var payload := state.to_dict()
	payload["save_version"] = SAVE_VERSION
	var text := JSON.stringify(payload, "\t")

	var path := slot_path(slot)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		save_failed.emit(slot, "open failed (%d)" % FileAccess.get_open_error())
		return false
	file.store_string(text)
	file.close()

	DebugLogger.info("campaign '%s' saved to %s (%d bytes)" % [
		state.campaign_name, path, text.length(),
	], "SaveManager")
	save_written.emit(slot, path)
	return true


func load_campaign(slot: int = SLOT_DEFAULT, config: GameConfig = null) -> CampaignState:
	var path := slot_path(slot)
	if not FileAccess.file_exists(path):
		DebugLogger.warn("no save at %s" % path, "SaveManager")
		return null
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		DebugLogger.error("save at %s is not a JSON object" % path, "SaveManager")
		return null

	var data := _migrate(parsed as Dictionary)
	var state := CampaignState.from_dict(data, config)
	if state.settlements.is_empty():
		DebugLogger.warn("loaded save has no settlements; the world builder will repopulate", "SaveManager")
	DebugLogger.info("campaign '%s' loaded from %s" % [state.campaign_name, path], "SaveManager")
	return state


## Applies any migration steps needed to bring an older document up to date.
func _migrate(data: Dictionary) -> Dictionary:
	var version := int(data.get("save_version", 0))
	if version == SAVE_VERSION:
		return data
	var migrated := data
	var guard := 0
	while version < SAVE_VERSION and guard < 64:
		guard += 1
		if MIGRATIONS.has(version):
			var fn: Callable = MIGRATIONS[version]
			migrated = fn.call(migrated) as Dictionary
		version += 1
		migrated["save_version"] = version
	if int(migrated.get("save_version", 0)) != SAVE_VERSION:
		DebugLogger.warn("save migrated to v%d (target v%d)" % [
			int(migrated.get("save_version", 0)), SAVE_VERSION,
		], "SaveManager")
	return migrated


func delete_save(slot: int = SLOT_DEFAULT) -> bool:
	var path := slot_path(slot)
	if not FileAccess.file_exists(path):
		return false
	var dir := DirAccess.open(SAVE_DIR)
	if dir == null:
		return false
	var err := dir.remove(path.get_file())
	DebugLogger.info("deleted save %s (%s)" % [path, "ok" if err == OK else "err %d" % err], "SaveManager")
	return err == OK


## Wipes every save in the slot directory. Used by the test suites.
func delete_all_saves() -> void:
	var dir := DirAccess.open(SAVE_DIR)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir() and entry.ends_with(".save"):
			dir.remove(entry)
		entry = dir.get_next()
	dir.list_dir_end()
