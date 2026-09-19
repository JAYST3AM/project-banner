class_name SettlementBuildings
extends RefCounted
## The modular settlement building system (D-138), built to the owner's art plan: decide what
## stands in a town from what the town is - its size, its wealth, the ground it sits on and the
## work it does - and describe every building the way a sprite will one day be assembled:
## category, condition, roof, walls, attachments and detail flags.
##
## The art plan's own order is kept: the system first, the sprites after. Nothing here draws
## anything; it decides. The settlement card reads the result today, the settlement scene will read
## the same result when buildings become sprites.
##
## Deterministic like the rest of the detail (D-136): a pure function of the campaign seed and the
## settlement's id, so two runs of a seed agree and nothing has to be saved to survive.

const CATALOGUE_PATH := "res://data/config/settlement_buildings.json"

## The catalogue, loaded once per run. Static so every caller shares the parse.
static var _catalogue: Dictionary = {}
## One world per seed, so pricing a town does not rebuild the terrain lattice per building.
static var _worlds: Dictionary = {}

## How many attachment pieces a building wears, and how many of those are clutter, before detail
## flags get a say.
const ATTACHMENTS_MIN := 1
const ATTACHMENTS_MAX := 2


static func catalogue() -> Dictionary:
	if _catalogue.is_empty():
		var text := FileAccess.get_file_as_string(CATALOGUE_PATH)
		var parsed = JSON.parse_string(text)
		if typeof(parsed) != TYPE_DICTIONARY:
			DebugLogger.warn("settlement buildings: could not read %s" % CATALOGUE_PATH,
				"SettlementBuildings")
			_catalogue = {"types": [], "attachments": [], "materials": {}, "conditions": {},
				"purposes": {}, "counts": {}}
		else:
			_catalogue = parsed as Dictionary
	return _catalogue


## All types, as an array of dictionaries.
static func types() -> Array:
	return catalogue().get("types", []) as Array


static func attachment_names() -> Dictionary:
	var names := {}
	for entry in (catalogue().get("attachments", []) as Array):
		names[str((entry as Dictionary).get("id", ""))] = str((entry as Dictionary).get("name", ""))
	return names


## ---------- the land ------------------------------------------------------

## What the ground at a place is, named the way the town's own description names it (world_builder
## reads the same numbers): "low and damp" is Coastal, "high and bare" is Highlands, the edge of
## the wild is Forest.
static func biome_at(position: Vector2, campaign_seed: int) -> String:
	var sample := land_sample(position, campaign_seed)
	var height := float(sample.get("height", 0.5))
	var region := float(sample.get("region", 0.5))
	if height > 0.68:
		return "Highlands"
	if height < 0.45:
		return "Coastal"
	if region < 0.5:
		return "Forest"
	var dry := float(sample.get("dry", 0.0))
	var lush := float(sample.get("lush", 0.0))
	var worn := float(sample.get("worn", 0.0))
	if dry > lush and dry > worn:
		return "Arid"
	return "Plains"


static func land_sample(position: Vector2, campaign_seed: int) -> Dictionary:
	if not _worlds.has(campaign_seed):
		_worlds[campaign_seed] = WorldChunks.build(campaign_seed)
	return (_worlds[campaign_seed] as WorldChunks).sample(position)


## What a place is for. The walls and the roads decide first, then the ground, then the market.
static func purpose_for(kind: String, biome: String, wealth: String) -> String:
	if kind == Settlement.TYPE_FORT or kind == Settlement.TYPE_CASTLE:
		return "military"
	if biome == "Coastal":
		return "fishing"
	if biome == "Highlands":
		return "mining"
	if kind == Settlement.TYPE_TOWN and wealth != "poor":
		return "market"
	return "farming"


## ---------- the plan ------------------------------------------------------

## One settlement's plan: {"biome", "purpose", "buildings"}. [param wealth] is passed in because the
## caller computes it first - the buildings' condition, gates and pocket all read it.
static func plan(settlement: Settlement, campaign_seed: int, wealth: String) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = campaign_seed + hash(settlement.id)
	var biome := biome_at(settlement.position, campaign_seed)
	var purpose := purpose_for(settlement.type, biome, wealth)
	var wanted := _count_for(settlement.type, rng)

	var chosen := _choose(settlement.type, biome, wealth, purpose, wanted, rng)
	_repair_trade(chosen, settlement.type, biome, wealth, purpose, rng)

	var buildings: Array = []
	for type_entry in chosen:
		buildings.append(_dress(type_entry as Dictionary, biome, wealth, rng))
	return {"biome": biome, "purpose": purpose, "buildings": buildings}


## How many buildings a place lists. Bounds come from the catalogue so a test can pin them.
static func _count_for(kind: String, rng: RandomNumberGenerator) -> int:
	var counts := catalogue().get("counts", {}) as Dictionary
	var bounds: Array = counts.get(kind, counts.get("village", [4, 6])) as Array
	var low := int(bounds[0])
	var high := int(bounds[1])
	return clampi(rng.randi_range(low, high), low, high)


## Which types stand here: the purpose's must-haves, then a house ladder, then weighted draws from
## every category, without repeating a type - a card lists one Cottages, not three.
static func _choose(kind: String, biome: String, wealth: String, purpose: String, wanted: int,
		rng: RandomNumberGenerator) -> Array:
	var pool := _eligible(kind, biome, wealth)
	var chosen: Array = []
	var used := {}

	var purpose_row: Dictionary = (catalogue().get("purposes", {}) as Dictionary).get(purpose, {}) as Dictionary
	for must_id in (purpose_row.get("must", []) as Array):
		_take_type(str(must_id), pool, chosen, used)

	# The house ladder: what a place's homes look like follows its wealth and its work.
	var ladder: Array[String] = ["cottage"]
	if wealth == "poor":
		ladder.append("hovel")
	if purpose == "farming":
		ladder.append("farmhouse")
	if kind == Settlement.TYPE_TOWN or kind == Settlement.TYPE_FORT or kind == Settlement.TYPE_CASTLE:
		ladder.append("townhouse")
	if wealth == "wealthy":
		ladder.append("manor_house")
	for id in ladder:
		if chosen.size() >= wanted:
			break
		_take_type(id, pool, chosen, used)

	var weights: Dictionary = purpose_row.get("weights", {}) as Dictionary
	if weights.is_empty():
		weights = {"residential": 4, "commercial": 3, "utility": 3, "military": 2, "special": 2}
	while chosen.size() < wanted:
		var category := _weighted_category(weights, rng)
		if not _take_from_category(category, pool, chosen, used, rng):
			# That category is spent; try the rest before giving up on the slot.
			var done := true
			for other in ["utility", "commercial", "special", "military", "residential"]:
				if _take_from_category(other, pool, chosen, used, rng):
					done = false
					break
			if done:
				break
	return chosen


## Types that may stand in this kind of place, on this ground, at this wealth.
static func _eligible(kind: String, biome: String, wealth: String) -> Array:
	var pool: Array = []
	for entry in types():
		var type_entry: Dictionary = entry as Dictionary
		var kinds: Array = type_entry.get("kinds", []) as Array
		if not kinds.has(kind):
			continue
		var biomes: Array = type_entry.get("biomes", []) as Array
		if not biomes.is_empty() and not biomes.has(biome):
			continue
		if not _wealth_gate_ok(str(type_entry.get("wealth", "")), wealth):
			continue
		pool.append(type_entry)
	return pool


## "poor" means only poor places have it; "wealthy" only rich ones; anything else is for all.
static func _wealth_gate_ok(gate: String, wealth: String) -> bool:
	match gate:
		"poor":
			return wealth == "poor"
		"modest":
			return wealth != "poor"
		"wealthy":
			return wealth == "wealthy"
		_:
			return true


static func _take_type(id: String, pool: Array, chosen: Array, used: Dictionary) -> bool:
	if used.has(id):
		return false
	for entry in pool:
		var type_entry: Dictionary = entry as Dictionary
		if str(type_entry.get("id", "")) == id:
			chosen.append(type_entry)
			used[id] = true
			return true
	return false


## A random unused type from a category, appended. False when the category has nothing left.
static func _take_from_category(category: String, pool: Array, chosen: Array, used: Dictionary,
		rng: RandomNumberGenerator) -> bool:
	var candidates: Array = []
	for entry in pool:
		var type_entry: Dictionary = entry as Dictionary
		if used.has(str(type_entry.get("id", ""))):
			continue
		if str(type_entry.get("category", "")) != category:
			continue
		candidates.append(type_entry)
	if candidates.is_empty():
		return false
	var pick: Dictionary = candidates[rng.randi_range(0, candidates.size() - 1)] as Dictionary
	chosen.append(pick)
	used[str(pick.get("id", ""))] = true
	return true


static func _weighted_category(weights: Dictionary, rng: RandomNumberGenerator) -> String:
	var total := 0
	for key in weights.keys():
		total += maxi(0, int(weights[key]))
	if total <= 0:
		return "utility"
	var roll := rng.randi_range(0, total - 1)
	for key in weights.keys():
		roll -= maxi(0, int(weights[key]))
		if roll < 0:
			return str(key)
	return "utility"


## The owner's trade rule (D-136) survives the new system: while the town can provide fewer than
## three goods, a building that provides nothing gives its place to one that does.
static func _repair_trade(chosen: Array, kind: String, biome: String, wealth: String,
		purpose: String, rng: RandomNumberGenerator) -> void:
	var purpose_row: Dictionary = (catalogue().get("purposes", {}) as Dictionary).get(purpose, {}) as Dictionary
	var must_ids: Array = purpose_row.get("must", []) as Array
	var guard := 0
	while _enabled_goods(chosen).size() < 3 and guard < 40:
		guard += 1
		var victim := _first_quiet(chosen, must_ids)
		if victim < 0:
			return
		var pool := _eligible(kind, biome, wealth)
		var used := {}
		for entry in chosen:
			used[str((entry as Dictionary).get("id", ""))] = true
		var donors: Array = []
		for entry in pool:
			var type_entry: Dictionary = entry as Dictionary
			var id := str(type_entry.get("id", ""))
			if used.has(id) or (type_entry.get("enables", []) as Array).is_empty():
				continue
			donors.append(type_entry)
		if donors.is_empty():
			return
		# Random donor, not the first in the catalogue: repaired towns must not all end up with
		# the same smithy in the same place.
		chosen[victim] = donors[rng.randi_range(0, donors.size() - 1)]


## The first building that provides nothing, preferring one that is not a home and never one the
## purpose demanded: the house ladder and the landmarks are the first things chosen and would
## otherwise be the first things the repair pass eats - the first version traded away each town's
## cottages, and the second traded away every castle's keep.
static func _first_quiet(chosen: Array, must_ids: Array) -> int:
	for index in chosen.size():
		var entry: Dictionary = chosen[index] as Dictionary
		if (entry.get("enables", []) as Array).is_empty() \
				and str(entry.get("category", "")) != "residential" \
				and not must_ids.has(str(entry.get("id", ""))):
			return index
	for index in chosen.size():
		if index == 0:
			continue
		var entry: Dictionary = chosen[index] as Dictionary
		if (entry.get("enables", []) as Array).is_empty() \
				and not must_ids.has(str(entry.get("id", ""))):
			return index
	return -1


## Every good the chosen types can provide, in order.
static func _enabled_goods(chosen: Array) -> Array[String]:
	var goods: Array[String] = []
	for entry in chosen:
		for good_any in ((entry as Dictionary).get("enables", []) as Array):
			var good := str(good_any)
			if not goods.has(good):
				goods.append(good)
	return goods


## ---------- dressing one building ----------------------------------------

## A building as the card (and, later, the sprite assembler) reads it: who it is, what state it is
## in, what it is made of, what is stacked against its wall.
static func _dress(type_entry: Dictionary, biome: String, wealth: String,
		rng: RandomNumberGenerator) -> Dictionary:
	var condition := _roll_condition(wealth, rng)
	var materials := _materials_for(biome)
	var roofs: Array = materials.get("roofs", ["weathered tile"]) as Array
	var walls: Array = materials.get("walls", ["dirty plaster"]) as Array
	var attachment_pool: Array = materials.get("attachments", []) as Array
	var names := attachment_names()

	var attachments: Array[String] = []
	if not attachment_pool.is_empty():
		var count := rng.randi_range(ATTACHMENTS_MIN, ATTACHMENTS_MAX)
		var bag: Array = attachment_pool.duplicate()
		for i in mini(count, bag.size()):
			var pick := str(bag[rng.randi_range(0, bag.size() - 1)])
			bag.erase(pick)
			if not attachments.has(pick):
				attachments.append(pick)

	# What the building IS dresses it too: a shop wants its hanging sign whatever the ground it
	# stands on, and a home wants a bench, a porch and a line of laundry. These rolls are what carry
	# the life/detail half of the attachment catalogue onto actual walls.
	var by_category: Dictionary = catalogue().get("category_attachments", {}) as Dictionary
	var category_rolls: Dictionary = by_category.get(
		str(type_entry.get("category", "")), {}) as Dictionary
	for attachment_any in category_rolls.keys():
		var attachment := str(attachment_any)
		if attachments.has(attachment):
			continue
		if rng.randf() < float(category_rolls[attachment_any]):
			attachments.append(attachment)

	# The art plan's detail flags: what a sprite assembler would toggle on this building.
	var details := {
		"chimney": rng.randf() < 0.7,
		"clutter": condition == "poor" or condition == "abandoned" or rng.randf() < 0.55,
		"sign": str(type_entry.get("category", "")) == "commercial" and rng.randf() < 0.75,
		"fence": rng.randf() < 0.45,
		"garden": str(type_entry.get("category", "")) == "residential" and rng.randf() < 0.5,
	}

	return {
		"id": str(type_entry.get("id", "")),
		"name": str(type_entry.get("name", "")),
		"category": str(type_entry.get("category", "")),
		"condition": condition,
		"condition_word": _condition_word(condition),
		"roof": str(roofs[rng.randi_range(0, roofs.size() - 1)]),
		"wall": str(walls[rng.randi_range(0, walls.size() - 1)]),
		"attachments": attachments,
		"attachment_names": _display_names(attachments, names),
		"details": details,
		"note": str(type_entry.get("note", "")),
		"enables": (type_entry.get("enables", []) as Array).duplicate(),
	}


static func _display_names(ids: Array[String], names: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for id in ids:
		out.append(str(names.get(id, id)))
	return out


static func _materials_for(biome: String) -> Dictionary:
	var materials: Dictionary = catalogue().get("materials", {}) as Dictionary
	return materials.get(biome, materials.get("Plains", {})) as Dictionary


## One condition per building, rolled on the settlement's wealth, then spoken in its own words.
static func _roll_condition(wealth: String, rng: RandomNumberGenerator) -> String:
	var conditions: Dictionary = catalogue().get("conditions", {}) as Dictionary
	var row: Dictionary = conditions.get(wealth, conditions.get("modest", {})) as Dictionary
	var weights: Dictionary = row.get("weights", {}) as Dictionary
	var total := 0
	for key in weights.keys():
		total += maxi(0, int(weights[key]))
	if total <= 0:
		return "average"
	var roll := rng.randi_range(0, total - 1)
	for key in weights.keys():
		roll -= maxi(0, int(weights[key]))
		if roll < 0:
			return str(key)
	return "average"


static func _condition_word(condition: String) -> String:
	var conditions: Dictionary = catalogue().get("conditions", {}) as Dictionary
	var display: Dictionary = conditions.get("display", {}) as Dictionary
	return str(display.get(condition, condition))
