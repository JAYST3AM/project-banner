class_name SettlementDetails
extends RefCounted
## The detail a settlement carries beyond its numbers: what stands in it, what it trades, which
## houses share it, how rich it is and how defended (D-136).
##
## Generated, never authored. Every field is a pure function of the campaign seed and the
## settlement's own id, so two runs of a seed agree, a save written before this existed regenerates
## the same town, and nothing here has to be serialised to survive.
##
## The owner's rule, added after the first pass: "when generating what the settlement provides, it
## must have the same buildings that produce that item." So trade is not rolled separately - it is
## read out of the buildings. Each building names the goods it can provide, produces are drawn from
## that union, and wants are drawn from the kind's list with everything the town can make removed.
## A town cannot sell wool it has no sheepfold for, and cannot want what its own smithy supplies.

## Bump when the generation rules change: a save whose detail predates this is regenerated on the
## next map entry, because the old rolls no longer describe the same town.
const DETAILS_VERSION := 2

## What may stand in each kind of place: [name, note, [goods it can provide]]. The note is one
## line, shown as a tooltip. Infrastructure buildings provide nothing and exist for the look of the
## place - the repair pass below only draws on the ones that do.
const BUILDINGS := {
	"village": [
		["Mill", "Grinds the village's grain; at harvest the whole valley smells of it.", ["grain"]],
		["Kitchen garden", "Rows of turnips and beans behind the palisade.", ["turnips"]],
		["Sheepfold", "Wool on the hoof, and the village's winter coat.", ["wool"]],
		["Dairy", "Cheese and butter, sold at the next market down the road.", ["cheese"]],
		["Woodcutter's yard", "Firewood stacked higher than the roofs.", ["firewood"]],
		["Stockyard", "Cattle pens along the road out; the hides go with the drovers.", ["hides"]],
		["Smithy", "Nails, hinges, and the odd spearhead.", ["tools"]],
		["Brewhouse", "The village ale, brewed strong and drunk young.", ["ale"]],
		["Tavern", "Ale, gossip and a fire - where rumours will wait, once taverns tell them.", []],
		["Well", "Clean water, and the place news is traded.", []],
		["Chapel", "A priest, a bell, and benches worn smooth.", []],
	],
	"town": [
		["Market square", "Stalls, a weigh-house, and a bell to open it.", []],
		["Weaver's hall", "Loom after loom, and the cloth the whole valley wears.", ["wool cloth"]],
		["Tannery", "On the downwind edge, for everyone's sake.", ["leather"]],
		["Smokehouse", "Salted and smoked meat, off to the castles.", ["salted meat"]],
		["Potter's yard", "Kiln smoke and stacked amphorae.", ["pottery"]],
		["Smithy", "Busier than a village's, and hungrier for iron.", ["tools"]],
		["Brewhouse", "The town ale, brewed strong and drunk young.", ["ale"]],
		["Tavern", "Ale, gossip and a fire - where rumours will wait, once taverns tell them.", []],
		["Stone walls", "Low, patched, and better than none.", []],
		["Barracks", "A watch that drills twice a week, when nothing else needs doing.", []],
		["Granary", "Holds what has to survive the winter.", []],
		["Chapel", "A priest, a bell, and benches worn smooth.", []],
		["Well", "Clean water, and the place news is traded.", []],
	],
	"fort": [
		["Barracks", "Every man here has a place in the line and knows it.", []],
		["Armoury", "Spears, shields, and a tally of both.", []],
		["Palisade", "Timber, and enough of it.", []],
		["Stables", "The army's horses, and the smith's temper.", ["horse tack"]],
		["Smithy", "Field repairs and cheap blades.", ["tools"]],
		["Charcoal burner", "Pits in the woods, smoking day and night.", ["charcoal"]],
		["Tannery", "On the downwind edge, for everyone's sake.", ["hides"]],
		["Well", "Dug inside the wall on purpose.", []],
	],
	"castle": [
		["Keep", "The last wall, and the family that owns it.", []],
		["Armoury", "Spears, shields, and a tally of both.", []],
		["Stables", "The army's horses, and the smith's temper.", ["horses"]],
		["Quarry", "Good stone, cut where the road can carry it.", ["stone"]],
		["Charcoal burner", "Pits in the woods, smoking day and night.", ["charcoal"]],
		["Smithy", "Field repairs and cheap blades.", ["tools"]],
		["Great hall", "Where the houses settle things, loudly.", []],
		["Chapel", "A priest, a bell, and benches worn smooth.", []],
		["Deep well", "Dug inside the wall on purpose, and deeper than the siege.", []],
	],
}

## What each kind of place wants, before the buildings take their cut. Deliberately disjoint from
## every good the kind's buildings can provide, so the subtraction below is belt and braces rather
## than the only thing keeping a town from wanting its own exports.
const WANTS_BY_KIND := {
	"village": ["iron", "salt", "wine", "cloth", "horses"],
	"town": ["iron", "wine", "spices", "horses", "salt"],
	"fort": ["grain", "salt", "wine", "cloth", "cheese"],
	"castle": ["wine", "silk", "spices", "grain", "salt"],
}

## The pool rivals are drawn from. The owning house is removed from it, so a town cannot be at odds
## with itself.
const FAMILY_NAMES := [
	"Varn", "Marrow", "Ashby", "Fenn", "Harrow", "Wexley", "Dunmore",
	"Blackbriar", "Thorne", "Falk", "Redwald", "Ostry", "Garlan", "Crowmere", "Sable",
]

## Soldiers per head of population, by kind. The garrison is an estimate the card shows with a "~".
const GARRISON_FACTOR := {
	"village": 0.012,
	"town": 0.020,
	"fort": 0.035,
	"castle": 0.050,
}


## Fill a settlement's detail in place. Idempotent per version: a settlement whose detail is already
## current keeps it, so this can be called on every map entry (fresh campaigns and old saves alike).
static func fill(settlement: Settlement, campaign_seed: int) -> void:
	if settlement == null or settlement.details_version >= DETAILS_VERSION:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = campaign_seed + hash(settlement.id)
	var kind := settlement.type

	# Buildings first, repaired until they can provide at least three goods; then trade read out of
	# them, so the card can never show a good the town has no building for.
	var picked := _pick_buildings(kind, rng)
	var enabled := _enabled_goods(picked)
	settlement.buildings = _as_dicts(picked)
	settlement.produces = _pick_from(enabled, rng)
	settlement.wants = _pick_wants(kind, enabled, rng)
	settlement.families = _families(settlement, rng)
	settlement.wealth = _wealth(settlement.population, rng)
	settlement.garrison = _garrison(kind, settlement.population, rng)
	settlement.details_version = DETAILS_VERSION


## ---------- buildings ----------------------------------------------------

## Three to seven buildings for the kind, with one repair pass: while the set can provide fewer
## than three goods, a building that provides nothing is swapped for a random one that does. The
## owner's rule needs the town to be able to make what it sells.
static func _pick_buildings(kind: String, rng: RandomNumberGenerator) -> Array:
	var pool: Array = BUILDINGS.get(kind, BUILDINGS["village"]) as Array
	var low := 3
	var high := 5
	match kind:
		"town", "fort":
			low = 4
			high = 6
		"castle":
			low = 5
			high = 7
	var count := clampi(rng.randi_range(low, high), 3, pool.size())
	var bag: Array = pool.duplicate()
	var picked: Array = []
	for i in count:
		picked.append(_take(bag, rng.randi_range(0, bag.size() - 1)))

	while _enabled_goods(picked).size() < 3:
		var victim := _quietest(picked)
		if victim < 0:
			break
		var donor := _take_producer(bag, rng)
		if donor.is_empty():
			break
		picked[victim] = donor
	return picked


## The first building that provides nothing, or -1 when every pick already trades.
static func _quietest(picked: Array) -> int:
	for index in picked.size():
		var entry: Array = picked[index] as Array
		if (entry[2] as Array).is_empty():
			return index
	return -1


## A random building from the bag that provides something, removed from it. Empty when none is left.
static func _take_producer(bag: Array, rng: RandomNumberGenerator) -> Array:
	var choices: Array = []
	for index in bag.size():
		var entry: Array = bag[index] as Array
		if not (entry[2] as Array).is_empty():
			choices.append(index)
	if choices.is_empty():
		return []
	return _take(bag, rng.randi_range(0, choices.size() - 1))


static func _take(bag: Array, index: int) -> Array:
	var entry: Array = bag[index] as Array
	bag.remove_at(index)
	return entry


## Every good the chosen buildings can provide, in the order they were picked.
static func _enabled_goods(picked: Array) -> Array[String]:
	var goods: Array[String] = []
	for entry_any in picked:
		var entry: Array = entry_any as Array
		for good_any in (entry[2] as Array):
			var good := str(good_any)
			if not goods.has(good):
				goods.append(good)
	return goods


static func _as_dicts(picked: Array) -> Array:
	var buildings: Array = []
	for entry_any in picked:
		var entry: Array = entry_any as Array
		var enables: Array[String] = []
		for good_any in (entry[2] as Array):
			enables.append(str(good_any))
		buildings.append({"name": str(entry[0]), "note": str(entry[1]), "enables": enables})
	return buildings


## ---------- trade --------------------------------------------------------

## Two or three distinct goods out of what the town can make.
static func _pick_from(pool: Array[String], rng: RandomNumberGenerator) -> Array[String]:
	var bag: Array[String] = pool.duplicate()
	var count := clampi(rng.randi_range(2, 3), 1, bag.size())
	var picked: Array[String] = []
	for i in count:
		var index := rng.randi_range(0, bag.size() - 1)
		picked.append(bag[index])
		bag.remove_at(index)
	return picked


## Two or three goods out of the kind's wants, minus anything the town can provide itself.
static func _pick_wants(kind: String, enabled: Array[String], rng: RandomNumberGenerator) -> Array[String]:
	var pool: Array[String] = []
	for good_any in (WANTS_BY_KIND.get(kind, WANTS_BY_KIND["village"]) as Array):
		var good := str(good_any)
		if not enabled.has(good):
			pool.append(good)
	var count := clampi(rng.randi_range(2, 3), 1, pool.size())
	var picked: Array[String] = []
	for i in count:
		var index := rng.randi_range(0, pool.size() - 1)
		picked.append(pool[index])
		pool.remove_at(index)
	return picked


## ---------- houses, wealth, garrison -------------------------------------

## The houses that share the settlement. The owning house is always first with the largest share;
## the rest split what is left. Powers always sum to 100.
static func _families(settlement: Settlement, rng: RandomNumberGenerator) -> Array:
	var owner := house_display(settlement.owner_faction_id)
	var count := 1
	match settlement.type:
		"village":
			count = 2 if rng.randf() < 0.45 else 1
		"town", "fort", "castle":
			count = rng.randi_range(2, 3)

	var families: Array = []
	var owner_power := clampi(rng.randi_range(45, 70) + (6 if settlement.type == "castle" else 0), 40, 78)
	families.append({"id": settlement.owner_faction_id, "name": owner, "power": owner_power})

	var left := 100 - owner_power
	var pool: Array = FAMILY_NAMES.duplicate()
	pool.erase(surname_of(settlement.owner_faction_id))
	for i in count - 1:
		var remaining := count - 1 - i
		var power := left if remaining == 1 else maxi(8, int(round(float(left) * rng.randf_range(0.35, 0.65))))
		power = mini(power, left - 8 * (remaining - 1))
		var surname := str(pool[rng.randi_range(0, pool.size() - 1)])
		pool.erase(surname)
		families.append({
			"id": "house_" + surname.to_lower(),
			"name": "House %s" % surname,
			"power": power,
		})
		left -= power
	if left > 0:
		families[0]["power"] = int(families[0]["power"]) + left
	return families


static func _wealth(population: int, rng: RandomNumberGenerator) -> String:
	var score := population + rng.randi_range(-250, 250)
	if score < 750:
		return "poor"
	if score < 1500:
		return "modest"
	return "wealthy"


static func _garrison(kind: String, population: int, rng: RandomNumberGenerator) -> int:
	var factor := float(GARRISON_FACTOR.get(kind, 0.012))
	return maxi(3, int(round(float(population) * factor * rng.randf_range(0.85, 1.15))))


## "house_caldreth" -> "House Caldreth", the way every screen already shows it.
static func house_display(faction_id: String) -> String:
	if faction_id.is_empty():
		return "Unclaimed"
	return faction_id.replace("_", " ").capitalize()


## "house_caldreth" -> "Caldreth", for keeping the owning house out of the rival pool.
static func surname_of(faction_id: String) -> String:
	var parts := faction_id.split("_", false)
	if parts.size() < 2:
		return ""
	return str(parts[parts.size() - 1]).capitalize()
