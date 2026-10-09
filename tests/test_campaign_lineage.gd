extends TestCase
## A pure genealogy foundation: no automatic pregnancy, random spouses,
## custody or inheritance until the campaign's rules are approved.

func run() -> void:
	await _tick()
	_test_people_are_identity_references_not_soldier_copies()
	_test_parent_links_and_ancestry()
	_test_atomic_invalid_parent_rejection()
	_test_guardianship_and_deaths()
	_test_round_trip_and_legacy_campaign_compatibility()
	_test_corrupt_graph_is_not_restored()
	_complete()


func _test_people_are_identity_references_not_soldier_copies() -> void:
	section("person registry preserves stable identity without inferring relatives")
	var family := CampaignLineage.new()
	equal(family.size(), 0, "new family registry is empty")
	check(not family.ensure_person("", "Nobody"), "empty IDs are invalid")
	check(not family.ensure_person("x", "Invalid", 0), "day zero is not a birth date")
	check(family.ensure_person("s_0001", "Rowan Ashdown"), "a known soldier ID can register")
	check(family.ensure_person("s_0001", "Changed Name"), "registration is idempotent")
	equal(family.size(), 1, "duplicate registration never creates another person")
	equal(family.person("s_0001").get("name"), "Rowan Ashdown",
		"repeat registration cannot overwrite identity")
	equal(family.person("s_0001").get("born_day"), CampaignLineage.UNKNOWN_DAY,
		"birth date is unknown, not guessed from a soldier's age")
	equal(family.parents_of("s_0001").size(), 0, "soldier is not assigned guessed parents")
	check(family.person("missing").is_empty(), "unknown person returns a safe empty record")


func _test_parent_links_and_ancestry() -> void:
	section("family connections support two parents and deterministic descendants")
	var family := CampaignLineage.new()
	for spec in [
		["grand", "Grandparent", 1],
		["parent", "Parent", 7000],
		["other", "Other parent", 7200],
		["child", "Child", 14000],
		["sibling", "Sibling", 15000]
	]:
		check(family.ensure_person(str(spec[0]), str(spec[1]), int(spec[2])),
			"family fixture person %s registers" % str(spec[0]))
	check(family.set_parents("parent", "grand"), "first generation links")
	check(family.set_parents("child", "parent", "other"), "two parents can be recorded")
	check(family.set_parents("sibling", "parent", "other"), "sibling shares the same parents")
	equal(family.parents_of("child"), ["parent", "other"], "parent order stays as entered")
	equal(family.children_of("parent"), ["child", "sibling"], "children sorted by stable ID")
	equal(family.children_of("other"), ["child", "sibling"], "second parent has same children")
	check(family.is_ancestor_of("grand", "child"), "ancestors include grandparents")
	check(family.is_ancestor_of("parent", "child"), "direct parent is an ancestor")
	check(not family.is_ancestor_of("child", "parent"), "ancestry is directional")
	check(not family.is_ancestor_of("other", "parent"), "co-parents are not made related")


func _test_atomic_invalid_parent_rejection() -> void:
	section("invalid parent transactions never corrupt an existing family tree")
	var family := CampaignLineage.new()
	family.ensure_person("a", "Older", 1)
	family.ensure_person("b", "Middle", 10000)
	family.ensure_person("c", "Young", 20000)
	check(family.set_parents("b", "a"), "valid initial link")
	check(family.set_parents("c", "b"), "valid grandchild link")
	var snapshot := family.to_dict()
	check(not family.set_parents("a", "c"), "descendant cannot parent an ancestor")
	check(not family.set_parents("c", "b", "b"), "duplicate parents are rejected")
	check(not family.set_parents("c", "b", "missing"), "unknown second parent rejects whole change")
	check(not family.set_parents("c", "c"), "self parenting is refused")
	check(not family.set_parents("b", "c"), "a child born later cannot be its parent's parent")
	check(not family.set_parents("missing", "a"), "a missing child cannot be modified")
	equal(family.to_dict(), snapshot, "all failed edits left every original link unchanged")
	check(family.set_parents("c", "", ""), "parents can be deliberately cleared")
	equal(family.parents_of("c").size(), 0, "an explicit unlink leaves no phantom ancestors")


func _test_guardianship_and_deaths() -> void:
	section("custody and death do not rewrite biological genealogy")
	var family := CampaignLineage.new()
	family.ensure_person("parent", "Parent", 10)
	family.ensure_person("relative", "Relative", 20)
	family.ensure_person("child", "Child", 10000)
	family.set_parents("child", "parent")
	check(family.set_guardian("child", "relative"), "guardian can differ from a parent")
	equal(family.person("child").get("guardian_id"), "relative", "guardian is explicitly recorded")
	check(not family.set_guardian("child", "child"), "a child cannot guard themself")
	check(not family.set_guardian("child", "missing"), "unknown guardian cannot be assigned")
	check(not family.mark_dead("relative", 1), "death before known birth is rejected")
	check(family.mark_dead("relative", 11000), "valid death is recorded once")
	equal(family.person("relative").get("died_day"), 11000, "death date is historical")
	equal(family.person("child").get("guardian_id"), "", "a deceased current guardian is cleared")
	check(not family.set_guardian("child", "relative"), "deceased person cannot regain live guardianship")
	check(not family.mark_dead("relative", 12000), "history is not rewritten by a second death")
	check(family.mark_dead("parent", 12000), "biological parent can die")
	equal(family.parents_of("child"), ["parent"], "dead parents stay in the family tree")
	check(family.is_ancestor_of("parent", "child"), "ancestry outlives parents")
	check(family.set_guardian("child", ""), "care can be left unassigned by explicit decision")


func _test_round_trip_and_legacy_campaign_compatibility() -> void:
	section("family relationships are part of the real campaign save shape")
	var state := CampaignState.create(GameManager.config(), "Kinfolk", 654321)
	var parent := Soldier.new()
	parent.id = "s_0100"
	parent.first_name = "Alena"
	parent.surname = "Vale"
	state.register_soldier(parent)
	var child := Soldier.new()
	child.id = "s_0101"
	child.first_name = "Tomas"
	child.surname = "Vale"
	state.register_soldier(child)
	equal(state.lineage.size(), 2, "soldiers register as people on creation")
	check(state.lineage.ensure_person("caregiver", "Aunt Mira"), "civilian identity can exist outside roster")
	check(state.lineage.set_parents(child.id, parent.id), "soldier family relation can be recorded")
	check(state.lineage.set_guardian(child.id, "caregiver"), "civilian guardian can be recorded")
	var save_shape := state.to_dict()
	var restored := CampaignState.from_dict(save_shape, GameManager.config())
	equal(restored.lineage.size(), 3, "campaign save restores soldiers and civilians")
	equal(restored.lineage.parents_of(child.id), [parent.id], "parent link persists")
	equal(restored.lineage.person(child.id).get("guardian_id"), "caregiver",
		"guardian persists independently from parentage")
	equal(restored.soldier(parent.id).full_name(), "Alena Vale", "soldier identity remains authoritative")
	# Copy the result rather than mutating live graph through an exported Dictionary.
	var exported := restored.lineage.to_dict()
	(exported["people"] as Dictionary).clear()
	equal(restored.lineage.size(), 3, "mutating saved data does not mutate live family")
	var identity := restored.lineage.person(child.id)
	identity["name"] = "Incorrect"
	equal(restored.lineage.person(child.id).get("name"), "Tomas Vale",
		"the public person snapshot is also a deep copy")
	# Saves written before this feature had no lineage field. Soldier identities
	# backfill, but no fabricated marriages, parents or children appear.
	var legacy := save_shape.duplicate(true)
	legacy.erase("lineage")
	var old := CampaignState.from_dict(legacy, GameManager.config())
	equal(old.lineage.size(), 2, "old saves backfill existing soldiers only")
	equal(old.lineage.parents_of(child.id).size(), 0, "old saves invent no relationships")
	equal(old.lineage.person(child.id).get("guardian_id"), "", "old saves invent no guardians")
	equal(old.soldiers.size(), 2, "old save migration does not duplicate soldiers")
	equal(old.next_soldier_id(), "s_0102", "lineage does not consume soldier IDs")


func _test_corrupt_graph_is_not_restored() -> void:
	section("damaged save input is sanitized instead of importing broken relationships")
	var corrupt := {
		"people": {
			"a": {"name": "A", "born_day": 1, "died_day": -1,
				"parent_ids": ["b"], "guardian_id": "missing"},
			"b": {"name": "B", "born_day": -1, "died_day": -1,
				"parent_ids": ["a"], "guardian_id": ""},
			"bad": {"name": "Invalid", "born_day": 0},
			"empty": "not a dictionary",
		}
	}
	var loaded := CampaignLineage.from_dict(corrupt)
	equal(loaded.size(), 2, "invalid or non-dictionary people are skipped")
	check(not (loaded.is_ancestor_of("a", "b") and loaded.is_ancestor_of("b", "a")),
		"save import does not produce ancestor loops")
	equal(loaded.person("a").get("guardian_id"), "", "dangling guardian is discarded")
	check(loaded.has_person("a") and loaded.has_person("b"), "valid identities survive damaged links")
