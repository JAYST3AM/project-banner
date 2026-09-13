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
## e.g. MIGRATIONS[1] would upgrade a v1 document to v2.
## Populated in [method _ready] so the entries can be Callables.
var migrations: Dictionary = {}


func _ready() -> void:
	# Version 0 means "a document written before saves carried a version field".
	# It is a real case worth handling: it is the shape any save made by an early
	# build has, and normalising it costs nothing.
	migrations[0] = Callable(self, "_migrate_0_to_1")


## v0 -> v1: no version field, and party membership may be a bare array.
func _migrate_0_to_1(data: Dictionary) -> Dictionary:
	var migrated := data
	var player_party: Variant = migrated.get("player_party", {})
	if typeof(player_party) == TYPE_ARRAY:
		migrated["player_party"] = {"member_ids": player_party}
	migrated["save_version"] = 1
	DebugLogger.info("save migrated from an unversioned document", "SaveManager")
	return migrated


func slot_path(slot: int = SLOT_DEFAULT) -> String:
	return "%s/slot_%d.save" % [SAVE_DIR, slot]


func ensure_dir() -> bool:
	var err := DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	return err == OK or err == ERR_ALREADY_EXISTS


func has_save(slot: int = SLOT_DEFAULT) -> bool:
	return FileAccess.file_exists(slot_path(slot))


## Lightweight read used by the main menu; never builds a CampaignState.
##
## [b]Deliberately shape-tolerant and deliberately non-mutating.[/b] Peeking must
## not rewrite a save file, and it has to work on documents the game might still
## refuse to load - a save from a newer build, say. So instead of running the
## migration chain, this understands every shape the migration path understands and
## falls back to defaults for anything it does not recognise. The authoritative
## upgrade still happens in [method load_campaign].
##
## That matters because a save the game claims is loadable must at least be
## [i]describable[/i]. Previously this assumed `player_party` was already a
## dictionary, so the exact legacy shape the v0 migration exists to handle would
## error here before the player ever pressed Continue.
func peek_metadata(slot: int = SLOT_DEFAULT) -> Dictionary:
	if not has_save(slot):
		return {}
	var text := FileAccess.get_file_as_string(slot_path(slot))
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var data := parsed as Dictionary

	var clock_data := _dictionary_at(data, "clock")
	var member_ids := _party_member_ids(data)
	var active := _count_fieldable(data, member_ids)

	return {
		"campaign_name": str(data.get("campaign_name", "Unnamed Campaign")),
		"campaign_seed": int(data.get("campaign_seed", 0)),
		"day": int(clock_data.get("day", 1)),
		"hour": float(clock_data.get("hour", 8.0)),
		"player_gold": int(data.get("player_gold", 0)),
		## Historical roster membership, the dead included.
		"party_size": member_ids.size(),
		## Soldiers still fit to take the field. This is what the menu shows.
		"party_active": active,
		"party_lost": maxi(0, member_ids.size() - active),
		"save_version": int(data.get("save_version", 0)),
		"app_version": str(data.get("app_version", "unknown")),
		"saved_at": str(data.get("last_saved_at", "")),
	}


## Safe nested-dictionary read: returns {} for anything that is not a dictionary.
func _dictionary_at(data: Dictionary, key: String) -> Dictionary:
	var raw: Variant = data.get(key, null)
	if typeof(raw) == TYPE_DICTIONARY:
		return raw as Dictionary
	return {}


## The player's party member ids, in whichever shape the document stores them.
## v0 stored a bare array; v1 stores an object with a member_ids field.
func _party_member_ids(data: Dictionary) -> Array:
	var raw: Variant = data.get("player_party", null)
	if typeof(raw) == TYPE_ARRAY:
		return raw as Array
	if typeof(raw) == TYPE_DICTIONARY:
		var ids: Variant = (raw as Dictionary).get("member_ids", null)
		if typeof(ids) == TYPE_ARRAY:
			return ids as Array
	return []


## How many of those members are alive and fieldable, read straight from the saved
## soldier records. Mirrors CampaignState.active_member_count() exactly, without
## needing the campaign to be built.
func _count_fieldable(data: Dictionary, member_ids: Array) -> int:
	var lookup := _dictionary_at(data, "soldiers")
	if lookup.is_empty():
		# No soldier records to inspect. Assume the whole roster is standing rather
		# than reporting a phantom force of zero.
		return member_ids.size()
	var count := 0
	for soldier_id in member_ids:
		var raw: Variant = lookup.get(str(soldier_id), null)
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var status := str((raw as Dictionary).get("status", Soldier.STATUS_ACTIVE))
		if status == Soldier.STATUS_ACTIVE or status == Soldier.STATUS_WOUNDED:
			count += 1
	return count


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
	payload["app_version"] = ProjectSettings.get_setting("application/config/version", "0.0.0")
	var text := JSON.stringify(payload, "	")

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

	var raw := parsed as Dictionary
	var version := int(raw.get("save_version", 0))
	if version > SAVE_VERSION:
		# Refusing is the safe move: an older build cannot know what a newer
		# document means, and loading it anyway would quietly discard fields.
		DebugLogger.error("save at %s was written by a newer version (%d > %d) - not loading" % [
			path, version, SAVE_VERSION,
		], "SaveManager")
		return null

	var data := _migrate(raw)
	var state := CampaignState.from_dict(data, config)
	if state.settlements.is_empty():
		DebugLogger.warn("loaded save has no settlements; the world builder will repopulate", "SaveManager")
	DebugLogger.info("campaign '%s' loaded from %s (save v%d)" % [
		state.campaign_name, path, int(data.get("save_version", SAVE_VERSION)),
	], "SaveManager")
	return state


## Applies any migration steps needed to bring an older document up to date.
func _migrate(data: Dictionary) -> Dictionary:
	var version := int(data.get("save_version", 0))
	if version >= SAVE_VERSION:
		return data
	var migrated := data
	var guard := 0
	while version < SAVE_VERSION and guard < 64:
		guard += 1
		if migrations.has(version):
			var fn: Callable = migrations[version]
			migrated = fn.call(migrated) as Dictionary
		version += 1
		migrated["save_version"] = version
	if int(migrated.get("save_version", 0)) != SAVE_VERSION:
		DebugLogger.warn("save migrated to v%d (target v%d)" % [
			int(migrated.get("save_version", 0)), SAVE_VERSION,
		], "SaveManager")
	return migrated


## True when a save exists but was written by a newer build than this one.
func is_save_too_new(slot: int = SLOT_DEFAULT) -> bool:
	if not has_save(slot):
		return false
	var text := FileAccess.get_file_as_string(slot_path(slot))
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return false
	return int((parsed as Dictionary).get("save_version", 0)) > SAVE_VERSION


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
