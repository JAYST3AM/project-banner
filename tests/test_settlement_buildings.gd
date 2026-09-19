extends TestCase
## The modular building system (D-138), built to the owner's art plan: what stands in a town is a
## reading of the town - its kind, its size, its wealth, the ground it sits on and the work it does.
##
## What this suite exists to pin down:
## [br]- the catalogue is sound: unique ids, known categories, real biomes and attachments;
## [br]- the land names a town honestly: every biome is one of the five, and a world is not one of them;
## [br]- purpose follows the walls and the ground before it follows anything else;
## [br]- wealth speaks: conditions and gates come from the pocket, not the dice alone;
## [br]- the house ladder follows the town, the vocabulary is closed, and a seed builds the same town.
## It ends by printing example towns, because "believable and varied" is judged by eye and the suite
## should hand something over to judge.

const SEED := 5150
const KINDS := ["village", "town", "fort", "castle"]
const BIOMES := ["Plains", "Forest", "Highlands", "Coastal", "Arid"]
const CATEGORIES := ["residential", "commercial", "utility", "military", "special"]


func run() -> void:
	await _tick()
	_test_catalogue_is_sound()
	_test_biomes_read_the_land()
	_test_purpose_follows_ground_and_walls()
	_test_wealth_speaks_through_condition_and_gates()
	_test_houses_follow_the_town()
	_test_vocabulary_is_closed()
	_test_same_seed_same_plan()
	_report_example_towns()
	_complete()


func _town(id: String, type: String = Settlement.TYPE_TOWN, population: int = 1200,
		position: Vector2 = Vector2.ZERO) -> Settlement:
	var s := Settlement.new()
	s.id = id
	s.name = id.capitalize()
	s.type = type
	s.owner_faction_id = "house_caldreth"
	s.population = population
	s.position = position
	SettlementDetails.fill(s, SEED)
	return s


func _test_catalogue_is_sound() -> void:
	section("the catalogue every settlement is built from")
	var seen := {}
	var ids_ok := true
	var category_ok := true
	var note_ok := true
	var kinds_ok := true
	var biomes_ok := true
	var gate_ok := true
	for entry in SettlementBuildings.types():
		var type_entry: Dictionary = entry as Dictionary
		var id := str(type_entry.get("id", ""))
		if id.is_empty() or seen.has(id):
			ids_ok = false
		seen[id] = true
		if not CATEGORIES.has(str(type_entry.get("category", ""))):
			category_ok = false
		if str(type_entry.get("note", "")).is_empty():
			note_ok = false
		for kind_any in (type_entry.get("kinds", []) as Array):
			if not KINDS.has(str(kind_any)):
				kinds_ok = false
		for biome_any in (type_entry.get("biomes", []) as Array):
			if not BIOMES.has(str(biome_any)):
				biomes_ok = false
		if not ["", "poor", "modest", "wealthy"].has(str(type_entry.get("wealth", ""))):
			gate_ok = false
	check(ids_ok, "every building type has a unique id")
	check(category_ok, "and stands in a known category")
	check(note_ok, "and carries its one-line note")
	check(kinds_ok, "and only stands in kinds of place that exist")
	check(biomes_ok, "and only names biomes the world has")
	check(gate_ok, "and only gates wealth the way the rules read it")
	greater(SettlementBuildings.types().size(), 30, "and there are enough types to not repeat")


func _test_biomes_read_the_land() -> void:
	section("the ground a town stands on is read, not rolled")
	var seen := {}
	var known_ok := true
	for i in 12:
		var position := Vector2(600.0 + float(i) * 830.0, 500.0 + float(i % 4) * 900.0)
		var biome := SettlementBuildings.biome_at(position, SEED)
		if not BIOMES.has(biome):
			known_ok = false
		seen[biome] = true
	check(known_ok, "every reading names a biome the world has")
	greater(seen.size(), 1, "and a stretch of world is not all one ground")


func _test_purpose_follows_ground_and_walls() -> void:
	section("purpose: the walls and the ground decide before anything else")
	equal(SettlementBuildings.purpose_for("castle", "Plains", "wealthy"), "military",
		"a castle is military ground whatever the fields around it")
	equal(SettlementBuildings.purpose_for("fort", "Forest", "poor"), "military", "and so is a fort")
	equal(SettlementBuildings.purpose_for("village", "Coastal", "poor"), "fishing",
		"a village by the water fishes")
	equal(SettlementBuildings.purpose_for("town", "Highlands", "modest"), "mining",
		"a town in the hills digs")
	equal(SettlementBuildings.purpose_for("town", "Plains", "wealthy"), "market",
		"a rich town on open ground is a market")
	equal(SettlementBuildings.purpose_for("village", "Plains", "poor"), "farming",
		"and a poor village on open ground farms")


func _test_wealth_speaks_through_condition_and_gates() -> void:
	section("wealth speaks: conditions and gates come from the pocket")
	var poor := _town("poorstead", Settlement.TYPE_VILLAGE, 300)
	equal(poor.wealth, "poor", "a small village is poor")
	var poor_conditions_ok := true
	var poor_words_ok := true
	var poor_types_ok := true
	for entry in poor.buildings:
		var info: Dictionary = entry as Dictionary
		var condition := str(info.get("condition", ""))
		if not ["poor", "average", "damaged", "abandoned"].has(condition):
			poor_conditions_ok = false
		if str(info.get("condition_word", "")).is_empty():
			poor_words_ok = false
	check(poor_conditions_ok, "a poor village's buildings are only in poor states")
	check(poor_words_ok, "and every building speaks its state in words")
	check(str(poor.buildings).contains("hovel"), "and its homes are rough hovels")

	var rich := _town("goldwick", Settlement.TYPE_TOWN, 2200)
	equal(rich.wealth, "wealthy", "a big town is wealthy")
	var rich_conditions_ok := true
	for entry in rich.buildings:
		var info: Dictionary = entry as Dictionary
		if not ["wealthy", "average", "repaired"].has(str(info.get("condition", ""))):
			rich_conditions_ok = false
	check(rich_conditions_ok, "a wealthy town's buildings are only in good states")
	check(str(rich.buildings).contains("manor_house"), "and the owning house keeps a manor in it")
	check(not str(poor.buildings).contains("guild_hall"),
		"and a village never grows a guild hall it cannot pay for")


func _test_houses_follow_the_town() -> void:
	section("the house ladder follows the town")
	check(str(_town("cots", Settlement.TYPE_VILLAGE, 300).buildings).contains("cottage"),
		"every village has its cottages")
	check(str(_town("lanes", Settlement.TYPE_TOWN, 1200).buildings).contains("townhouse"),
		"a town has townhouses")
	# Twelve castles, because the trade repair pass ate the keep in one castle in forty and a
	# single castle was not enough to catch it (it was: the sweep in test_sprite_list saw it).
	var keeps_ok := true
	for i in 12:
		var castle := _town("keep_%d" % i, Settlement.TYPE_CASTLE, 700 + i * 160,
			Vector2(400.0 + float(i) * 700, 2400.0))
		if not str(castle.buildings).contains("keep"):
			keeps_ok = false
	check(keeps_ok, "every castle keeps its keep")


func _test_vocabulary_is_closed() -> void:
	section("every building is made of words the catalogue knows")
	var materials: Dictionary = SettlementBuildings.catalogue().get("materials", {}) as Dictionary
	var attachment_ids := SettlementBuildings.attachment_names().keys()
	var roofs_ok := true
	var walls_ok := true
	var attachments_ok := true
	var details_ok := true
	var conditions := {}
	for i in 8:
		var s := _town("v%d" % i, KINDS[i % KINDS.size()], 400 + i * 250,
			Vector2(700.0 + float(i) * 640.0, 800.0))
		conditions[s.wealth] = true
		var row: Dictionary = materials.get(s.biome, {}) as Dictionary
		var roofs: Array = row.get("roofs", []) as Array
		var walls: Array = row.get("walls", []) as Array
		for entry in s.buildings:
			var info: Dictionary = entry as Dictionary
			if not roofs.has(str(info.get("roof", ""))):
				roofs_ok = false
			if not walls.has(str(info.get("wall", ""))):
				walls_ok = false
			for attachment in (info.get("attachments", []) as Array):
				if not attachment_ids.has(attachment):
					attachments_ok = false
			var details: Dictionary = info.get("details", {}) as Dictionary
			for key in ["chimney", "clutter", "sign", "fence", "garden"]:
				if not details.has(key):
					details_ok = false
	check(roofs_ok, "every roof is a material the town's ground allows")
	check(walls_ok, "and so is every wall")
	check(attachments_ok, "and everything stacked against them is a real attachment")
	check(details_ok, "and every building carries the art plan's toggles")


func _test_same_seed_same_plan() -> void:
	section("one seed, one town - buildings and all")
	var first := _town("twin", Settlement.TYPE_TOWN, 1200, Vector2(1500.0, 1100.0))
	var second := _town("twin", Settlement.TYPE_TOWN, 1200, Vector2(1500.0, 1100.0))
	equal(str(first.buildings), str(second.buildings), "the same town twice")
	equal(first.biome, second.biome, "standing on the same ground")


func _report_example_towns() -> void:
	section("four towns, as the system builds them")
	var places := [
		["millcross", Settlement.TYPE_VILLAGE, 380, Vector2(900.0, 1400.0)],
		["stonegate", Settlement.TYPE_TOWN, 1900, Vector2(2100.0, 900.0)],
		["harbourwatch", Settlement.TYPE_FORT, 900, Vector2(300.0, 2600.0)],
		["highharrow", Settlement.TYPE_CASTLE, 1400, Vector2(2600.0, 2400.0)],
	]
	for place in places:
		var s := _town(str(place[0]), str(place[1]), int(place[2]), place[3] as Vector2)
		var names: Array[String] = []
		for entry in s.buildings:
			var info: Dictionary = entry as Dictionary
			names.append("%s (%s)" % [str(info.get("name", "?")), str(info.get("condition", "?"))])
		var sample: Dictionary = s.buildings[0] as Dictionary
		print("report: %s | %s | %s | %s | %d buildings: %s" % [
			s.name, s.type, s.biome, s.wealth, s.buildings.size(), ", ".join(names)])
		print("report:   first building dressed: %s, %s roof, %s walls, around it: %s" % [
			str(sample.get("condition_word", "")), str(sample.get("roof", "")),
			str(sample.get("wall", "")), ", ".join(sample.get("attachment_names", []) as Array)])
	check(true, "reported")
