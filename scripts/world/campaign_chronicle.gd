class_name CampaignChronicle
extends RefCounted
## Save-safe campaign history. The campaign owns it through its already-versioned
## flags bag, so old saves load without migration. We record events only after
## successful game transactions, never while drawing or inspecting the UI.
##
## BattleResolver already persists battle_log (up to forty results). Read those
## records directly instead of double-writing every battle or changing its
## carefully tested outcome path.

const STORE_KEY := "campaign_chronicle"
const KINDS: Array[String] = ["recruitment", "travel", "family", "milestone"]
const DEFAULT_RECENT := 60


## Record one completed event. Invalid input is rejected without changing flags.
static func record(state: CampaignState, kind: String, title: String,
		detail: String = "", person_id: String = "",
		place_id: String = "") -> bool:
	if state == null or state.clock == null or not KINDS.has(kind):
		return false
	if title.strip_edges().is_empty() or state.clock.day < 1:
		return false
	var stored: Variant = state.flags.get(STORE_KEY, {})
	var ledger: Dictionary = stored.duplicate(true) if typeof(stored) == TYPE_DICTIONARY else {}
	var raw_entries: Variant = ledger.get("entries", [])
	if typeof(raw_entries) != TYPE_ARRAY:
		return false # Do not silently discard an existing malformed ledger.
	var events := (raw_entries as Array).duplicate(true)
	var next_id := maxi(1, int(ledger.get("next_id", 1)))
	# All entries have a unique monotonically increasing ID. This does not
	# depend on wall time or dictionary iteration order.
	var event := {
		"id": "evt_%08d" % next_id,
		"kind": kind,
		"day": state.clock.day,
		"hour": state.clock.hour,
		"title": title.strip_edges().substr(0, 160),
		"detail": detail.strip_edges().substr(0, 600),
		"person_id": person_id,
		"place_id": place_id,
	}
	events.append(event)
	ledger["entries"] = events
	ledger["next_id"] = next_id + 1
	state.flags[STORE_KEY] = ledger
	return true


## Return a fresh snapshot. The order is most recent first, with an explicit
## tie-break for events occurring at the same campaign time.
## kind = "" means all; "battle" reads the existing battle history.
static func recent(state: CampaignState, limit: int = DEFAULT_RECENT,
		kind: String = "") -> Array[Dictionary]:
	var combined: Array[Dictionary] = []
	if state == null or limit <= 0:
		return combined
	var stored: Variant = state.flags.get(STORE_KEY, {})
	if typeof(stored) == TYPE_DICTIONARY:
		var entries: Variant = (stored as Dictionary).get("entries", [])
		if typeof(entries) == TYPE_ARRAY:
			for raw in entries:
				if typeof(raw) != TYPE_DICTIONARY:
					continue
				var event := raw as Dictionary
				if not _valid(event):
					continue
				if not kind.is_empty() and str(event.get("kind", "")) != kind:
					continue
				combined.append(event.duplicate(true))
	if kind.is_empty() or kind == "battle":
		# The battle system is the authority for these existing records.
		var raw_battles: Variant = state.flags.get("battle_log", [])
		if typeof(raw_battles) == TYPE_ARRAY:
			for raw in raw_battles:
				if typeof(raw) != TYPE_DICTIONARY:
					continue
				var battle := _from_battle(raw as Dictionary)
				if not battle.is_empty():
					combined.append(battle)
	combined.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var day_a := int(a.get("day", 0))
		var day_b := int(b.get("day", 0))
		if day_a != day_b:
			return day_a > day_b
		var hour_a := float(a.get("hour", 0.0))
		var hour_b := float(b.get("hour", 0.0))
		if not is_equal_approx(hour_a, hour_b):
			return hour_a > hour_b
		return str(a.get("id", "")) > str(b.get("id", "")))
	if combined.size() > limit:
		combined.resize(limit)
	return combined


static func for_person(state: CampaignState, person_id: String,
		limit: int = DEFAULT_RECENT) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	if person_id.is_empty() or limit <= 0:
		return found
	# Deliberately exclude the battle-log summary, which lists names but
	# does not identify participants reliably by persistent person ID.
	for entry in recent(state, 1000000):
		if str(entry.get("person_id", "")) == person_id:
			found.append(entry)
			if found.size() >= limit:
				break
	return found


static func count_recorded(state: CampaignState) -> int:
	if state == null:
		return 0
	var stored: Variant = state.flags.get(STORE_KEY, {})
	if typeof(stored) != TYPE_DICTIONARY:
		return 0
	var raw: Variant = (stored as Dictionary).get("entries", [])
	return (raw as Array).size() if typeof(raw) == TYPE_ARRAY else 0


static func _valid(entry: Dictionary) -> bool:
	return not str(entry.get("id", "")).is_empty() \
		and not str(entry.get("title", "")).strip_edges().is_empty() \
		and KINDS.has(str(entry.get("kind", ""))) \
		and int(entry.get("day", 0)) >= 1


static func _from_battle(raw: Dictionary) -> Dictionary:
	var battle_id := str(raw.get("battle_id", ""))
	var day := int(raw.get("day", 0))
	if battle_id.is_empty() or day < 1:
		return {}
	var outcome := str(raw.get("winner", "draw")).to_upper()
	if bool(raw.get("withdrawal", false)):
		outcome = "WITHDRAWAL"
	var enemy := str(raw.get("enemy", "Unknown opponent"))
	var losses := maxi(0, int(raw.get("player_dead", 0)))
	var enemies_down := maxi(0, int(raw.get("enemy_dead", 0)))
	return {
		"id": "battle:%s" % battle_id,
		"kind": "battle",
		"day": day,
		"hour": float(raw.get("hour", 0.0)),
		"title": "%s against %s" % [outcome.capitalize(), enemy],
		"detail": "%d fallen · %d enemies defeated · %d gold" % [
			losses, enemies_down, int(raw.get("gold", 0))],
		"person_id": "",
		"place_id": "",
	}
