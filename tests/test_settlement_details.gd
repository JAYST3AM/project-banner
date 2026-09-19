extends TestCase
## The generated settlement detail (D-136): buildings, trade, houses and their power, wealth and
## garrison - the card a settlement grows on hover.
##
## What this suite exists to pin down:
## [br]- the same seed and id always produce the same town, and different ids do not;
## [br]- the owning house always leads, and powers always sum to 100;
## [br]- what a place makes, it never also wants;
## [br]- wealth and garrison follow population and kind;
## [br]- a save written before this existed backfills on load, and filling twice changes nothing.

const SEED := 5150
const KINDS := ["village", "town", "fort", "castle"]
## How many buildings each kind of place lists (D-138; the catalogue's own counts).
const KIND_BUILDING_BOUNDS := {
	"village": [4, 6],
	"town": [6, 10],
	"fort": [5, 8],
	"castle": [5, 8],
}


func run() -> void:
	await _tick()
	_test_same_seed_same_details()
	_test_different_ids_differ()
	_test_owner_leads_and_powers_sum()
	_test_buildings_are_a_list_of_places()
	_test_trade_never_overlaps()
	_test_trade_comes_from_the_buildings()
	_test_wealth_and_garrison()
	_test_old_saves_backfill_and_filling_twice_changes_nothing()
	_test_details_survive_a_round_trip()
	_complete()


func _town(id: String, type: String = Settlement.TYPE_TOWN, population: int = 1200) -> Settlement:
	var s := Settlement.new()
	s.id = id
	s.name = id.capitalize()
	s.type = type
	s.owner_faction_id = "house_caldreth"
	s.population = population
	SettlementDetails.fill(s, SEED)
	return s


func _signature(s: Settlement) -> String:
	return "%s|%s|%s|%d" % [str(s.buildings), str(s.families), s.wealth, s.garrison]


func _test_same_seed_same_details() -> void:
	section("the same seed and id always produce the same town")
	var a := _town("stoneford")
	var b := _town("stoneford")
	equal(_signature(a), _signature(b), "the same buildings, houses, wealth and garrison")


func _test_different_ids_differ() -> void:
	section("different settlements are different towns")
	var seen := {}
	for i in 8:
		seen[_signature(_town("place_%d" % i))] = true
	greater(seen.size(), 3, "eight settlements do not collapse into one")


func _test_owner_leads_and_powers_sum() -> void:
	section("the owning house leads and the powers are shares of a hundred")
	var sums_ok := true
	var leads_ok := true
	var counts_ok := true
	var powers_ok := true
	for i in 40:
		var s := _town("t%d" % i, KINDS[i % KINDS.size()])
		var sum := 0
		for entry in s.families:
			var family: Dictionary = entry as Dictionary
			var power := int(family.get("power", 0))
			sum += power
			if power < 1:
				powers_ok = false
		if sum != 100:
			sums_ok = false
		if str((s.families[0] as Dictionary).get("id", "")) != s.owner_faction_id:
			leads_ok = false
		if s.families.size() < 1 or s.families.size() > 3:
			counts_ok = false
	check(sums_ok, "every town's house powers sum to 100")
	check(leads_ok, "the owning house is always the leading house")
	check(counts_ok, "every town has one to three houses")
	check(powers_ok, "a house with power always has some")


func _test_buildings_are_a_list_of_places() -> void:
	section("every town stands somewhere: named buildings, in the kind's count band")
	var counts_ok := true
	var named_ok := true
	var unique_ok := true
	for i in 40:
		var s := _town("b%d" % i, KINDS[i % KINDS.size()])
		var bounds: Array = KIND_BUILDING_BOUNDS.get(s.type, [4, 6]) as Array
		if s.buildings.size() < int(bounds[0]) or s.buildings.size() > int(bounds[1]):
			counts_ok = false
		var seen := {}
		for entry in s.buildings:
			var info: Dictionary = entry as Dictionary
			if str(info.get("name", "")).is_empty() or str(info.get("note", "")).is_empty():
				named_ok = false
			if seen.has(str(info.get("name", ""))):
				unique_ok = false
			seen[str(info.get("name", ""))] = true
	check(counts_ok, "every settlement lists the buildings its kind's band allows (D-138)")
	check(named_ok, "and every building has a name and a note")
	check(unique_ok, "and no building is listed twice")


func _test_trade_never_overlaps() -> void:
	section("what a place makes, it never also wants")
	var sizes_ok := true
	var disjoint_ok := true
	for i in 40:
		var s := _town("g%d" % i, KINDS[i % KINDS.size()])
		# Sells stays at two or three from the buildings; wants is the staples it cannot make plus
		# one or two off its kind's basket (D-140: the baskets went wide so nothing dead-ends).
		if s.produces.size() < 2 or s.produces.size() > 3 or s.wants.size() < 2 or s.wants.size() > 5:
			sizes_ok = false
		for good in s.produces:
			if s.wants.has(good):
				disjoint_ok = false
	check(sizes_ok, "every town trades two or three goods out and a few in")
	check(disjoint_ok, "and produces and wants never share a good")


func _test_trade_comes_from_the_buildings() -> void:
	section("what a place sells, it can make: the buildings provide it")
	var produces_ok := true
	var wants_ok := true
	for i in 40:
		var s := _town("p%d" % i, KINDS[i % KINDS.size()])
		var enabled := {}
		for entry in s.buildings:
			var info: Dictionary = entry as Dictionary
			for good_any in (info.get("enables", []) as Array):
				enabled[str(good_any)] = true
		for good in s.produces:
			if not enabled.has(good):
				produces_ok = false
		for good in s.wants:
			if enabled.has(good):
				wants_ok = false
	check(produces_ok, "every produced good has a building that provides it")
	check(wants_ok, "and nothing a town can make sits on its own wants list")


func _test_wealth_and_garrison() -> void:
	section("wealth and garrison follow the people and the walls")
	equal(_town("small", Settlement.TYPE_VILLAGE, 400).wealth, "poor", "a hamlet is poor")
	equal(_town("big", Settlement.TYPE_TOWN, 2200).wealth, "wealthy", "a big town is wealthy")
	var village := _town("clash", Settlement.TYPE_VILLAGE, 1000)
	var castle := _town("clash", Settlement.TYPE_CASTLE, 1000)
	greater(castle.garrison, village.garrison,
		"a castle keeps more spears than a village of the same size")
	greater(village.garrison, 0, "and a village still keeps some")
	less(village.garrison, 1000, "but a garrison is a fraction of its people")


func _test_old_saves_backfill_and_filling_twice_changes_nothing() -> void:
	section("a save from before this existed grows its detail on load")
	var data := {
		"id": "oldsave", "name": "Oldsave", "type": "town", "population": 1200,
		"owner_faction_id": "house_caldreth",
	}
	var s := Settlement.from_dict(data)
	check(s.buildings.is_empty(), "the old save carries no detail")
	SettlementDetails.fill(s, SEED)
	check(not s.buildings.is_empty(), "and the backfill gives it some")
	equal(s.details_version, SettlementDetails.DETAILS_VERSION, "at the current rules version")
	var before := str(s.to_dict())
	SettlementDetails.fill(s, SEED)
	equal(str(s.to_dict()), before, "filling twice changes nothing")


func _test_details_survive_a_round_trip() -> void:
	section("the detail survives a save and load")
	var s := _town("saved")
	s.last_visited_day = 7
	var copy := Settlement.from_dict(s.to_dict())
	equal(copy.last_visited_day, 7, "the last-visited stamp survives a save")
	equal(str(copy.families), str(s.families), "and so do the houses")
	equal(str(copy.buildings), str(s.buildings), "and the buildings")
	equal(copy.garrison, s.garrison, "and the garrison")
	equal(copy.wealth, s.wealth, "and the wealth")
	equal(copy.details_version, s.details_version, "and the rules version it was built with")
