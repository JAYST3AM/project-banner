class_name CampaignLineage
extends RefCounted
## Save-safe family relationships for campaign people.
##
## This is the identity graph, NOT a fertility, succession, aging, romance or
## inheritance simulator. Those decisions belong to later gameplay systems.
## Soldier identity remains owned by CampaignState; this registry refers to IDs
## and does not duplicate mutable Soldier stats.
##
## Parent links are directional, limited to two, cycle-free and applied atomically.
## Guardianship means current care, not parentage or automatic child assignment.

const UNKNOWN_DAY := -1

var _people: Dictionary = {}


func size() -> int:
	return _people.size()


func has_person(person_id: String) -> bool:
	return _people.has(person_id)


func person(person_id: String) -> Dictionary:
	if not _people.has(person_id):
		return {}
	return (_people[person_id] as Dictionary).duplicate(true)


## No random names, genders, birth dates or parenthood inferred from a roster.
## Existing people's family records are deliberately never overwritten.
func ensure_person(person_id: String, display_name: String, born_day: int = UNKNOWN_DAY) -> bool:
	var id := person_id.strip_edges()
	if id.is_empty() or (born_day < 1 and born_day != UNKNOWN_DAY):
		return false
	if _people.has(id):
		return true
	_people[id] = {
		"id": id,
		"name": display_name.strip_edges(),
		"born_day": born_day,
		"died_day": UNKNOWN_DAY,
		"parent_ids": [],
		"guardian_id": "",
	}
	return true


func parents_of(person_id: String) -> Array[String]:
	var result: Array[String] = []
	if not _people.has(person_id):
		return result
	for parent_id in (_people[person_id] as Dictionary).get("parent_ids", []):
		result.append(str(parent_id))
	return result


func children_of(person_id: String) -> Array[String]:
	var result: Array[String] = []
	if not _people.has(person_id):
		return result
	for id in _people.keys():
		if parents_of(str(id)).has(person_id):
			result.append(str(id))
	result.sort()
	return result


func is_ancestor_of(ancestor_id: String, descendant_id: String) -> bool:
	if not _people.has(ancestor_id) or not _people.has(descendant_id):
		return false
	var to_visit: Array[String] = parents_of(descendant_id)
	var seen: Dictionary = {}
	while not to_visit.is_empty():
		var current := to_visit.pop_back()
		if current == ancestor_id:
			return true
		if seen.has(current):
			continue
		seen[current] = true
		for parent_id in parents_of(current):
			if not seen.has(parent_id):
				to_visit.append(parent_id)
	return false


## An atomic edit: no parent link changes until BOTH candidates validate.
## An empty parent list is a deliberate unlink, never an implied death.
func set_parents(child_id: String, first_parent_id: String,
		second_parent_id: String = "") -> bool:
	if not _people.has(child_id):
		return false
	var wanted: Array[String] = []
	for candidate in [first_parent_id, second_parent_id]:
		var id := candidate.strip_edges()
		if id.is_empty():
			continue
		if id == child_id or wanted.has(id) or not _people.has(id):
			return false
		# A descendant cannot become an ancestor of its own ancestor.
		if is_ancestor_of(child_id, id):
			return false
		var child_birth := int((_people[child_id] as Dictionary).get("born_day", UNKNOWN_DAY))
		var parent_birth := int((_people[id] as Dictionary).get("born_day", UNKNOWN_DAY))
		if child_birth != UNKNOWN_DAY and parent_birth != UNKNOWN_DAY and parent_birth >= child_birth:
			return false
		wanted.append(id)
	(_people[child_id] as Dictionary)["parent_ids"] = wanted
	return true


## Care can be assigned separately from lineage. No default guardian is
## chosen for children; a later gameplay rule or player decision must do that.
func set_guardian(child_id: String, guardian_id: String) -> bool:
	if not _people.has(child_id):
		return false
	if not guardian_id.is_empty():
		if guardian_id == child_id or not _people.has(guardian_id):
			return false
		if int((_people[guardian_id] as Dictionary).get("died_day", UNKNOWN_DAY)) != UNKNOWN_DAY:
			return false
	(_people[child_id] as Dictionary)["guardian_id"] = guardian_id
	return true


## Death is irreversible history. Clear live care relationships, but preserve
## ancestry (even when every ancestor has died).
func mark_dead(person_id: String, day: int) -> bool:
	if not _people.has(person_id) or day < 1:
		return false
	var person_data := _people[person_id] as Dictionary
	if int(person_data.get("died_day", UNKNOWN_DAY)) != UNKNOWN_DAY:
		return false
	var birth_day := int(person_data.get("born_day", UNKNOWN_DAY))
	if birth_day != UNKNOWN_DAY and day < birth_day:
		return false
	person_data["died_day"] = day
	for id in _people.keys():
		var record := _people[id] as Dictionary
		if str(record.get("guardian_id", "")) == person_id:
			record["guardian_id"] = ""
	return true


func to_dict() -> Dictionary:
	# Deep copy prevents outside code mutating the live graph through save data.
	return {"people": _people.duplicate(true)}


static func from_dict(data: Dictionary) -> CampaignLineage:
	var registry := CampaignLineage.new()
	var raw: Variant = data.get("people", {})
	if typeof(raw) != TYPE_DICTIONARY:
		return registry
	var source := raw as Dictionary
	var ids := source.keys()
	ids.sort()
	# First load people without references; entries can be out of order.
	for key in ids:
		var record: Variant = source[key]
		if typeof(record) != TYPE_DICTIONARY:
			continue
		var fields := record as Dictionary
		var day := int(fields.get("born_day", UNKNOWN_DAY))
		registry.ensure_person(str(key), str(fields.get("name", "")), day)
	# Then validate relationships through the same public transactions.
	for key in ids:
		var id := str(key)
		if not registry.has_person(id) or typeof(source[key]) != TYPE_DICTIONARY:
			continue
		var fields := source[key] as Dictionary
		var raw_parents: Variant = fields.get("parent_ids", [])
		if typeof(raw_parents) == TYPE_ARRAY:
			var candidates := raw_parents as Array
			if candidates.size() <= 2:
				var first := str(candidates[0]) if candidates.size() >= 1 else ""
				var second := str(candidates[1]) if candidates.size() == 2 else ""
				registry.set_parents(id, first, second)
		var death_day := int(fields.get("died_day", UNKNOWN_DAY))
		if death_day != UNKNOWN_DAY:
			registry.mark_dead(id, death_day)
	# Guardians run last so a saved dead guardian can never be restored.
	for key in ids:
		var id := str(key)
		if not registry.has_person(id) or typeof(source[key]) != TYPE_DICTIONARY:
			continue
		var fields := source[key] as Dictionary
		registry.set_guardian(id, str(fields.get("guardian_id", "")))
	return registry
