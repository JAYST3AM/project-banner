class_name SettlementDetails
extends RefCounted
## The detail a settlement carries beyond its numbers: what stands in it, what it trades, which
## houses share it, how rich it is and how defended (D-136).
##
## Generated, never authored. Every field is a pure function of the campaign seed and the
## settlement's own id, so two runs of a seed agree, a save written before this existed regenerates
## the same town, and nothing here has to be serialised to survive. The owner asked for it shown on
## hover: "this is going to be the settlements details ... building listings, trade goods,
## population, (scouted info), noble families and their power % in that settlement."

## What may stand in each kind of place. The note is one line, shown as a tooltip - the card keeps
## names lean and prose on hover.
const BUILDINGS := {
	"village": [
		["Mill", "Grinds the village's grain; at harvest the whole valley smells of it."],
		["Well", "Clean water, and the place news is traded."],
		["Chapel", "A priest, a bell, and benches worn smooth."],
		["Granary", "Holds what has to survive the winter."],
		["Smithy", "Nails, hinges, and the odd spearhead."],
		["Stockyard", "Cattle pens along the road out."],
		["Tavern", "Ale and gossip - where rumours will wait, once taverns tell them."],
	],
	"town": [
		["Market square", "Stalls, a weigh-house, and a bell to open it."],
		["Smithy", "Busier than a village's, and hungrier for iron."],
		["Stone walls", "Low, patched, and better than none."],
		["Barracks", "A watch that drills twice a week, when nothing else needs doing."],
		["Granary", "Holds what has to survive the winter."],
		["Chapel", "A priest, a bell, and benches worn smooth."],
		["Tavern", "Ale and gossip - where rumours will wait, once taverns tell them."],
	],
	"fort": [
		["Barracks", "Every man here has a place in the line and knows it."],
		["Armoury", "Spears, shields, and a tally of both."],
		["Palisade", "Timber, and enough of it."],
		["Stables", "The army's horses, and the smith's temper."],
		["Well", "Dug inside the wall on purpose."],
		["Smithy", "Field repairs and cheap blades."],
	],
	"castle": [
		["Keep", "The last wall, and the family that owns it."],
		["Armoury", "Spears, shields, and a tally of both."],
		["Stables", "The army's horses, and the smith's temper."],
		["Great hall", "Where the houses settle things, loudly."],
		["Chapel", "A priest, a bell, and benches worn smooth."],
		["Deep well", "Dug inside the wall on purpose, and deeper than the siege."],
		["Stone walls", "High, and kept that way."],
	],
}

## What each kind of place makes and lacks. The two lists of a kind never share a word: a town
## cannot want what it makes.
const GOODS_BY_KIND := {
	"village": {
		"produces": ["grain", "wool", "turnips", "cheese", "firewood", "hides"],
		"wants": ["iron", "salt", "tools", "wine", "cloth"],
	},
	"town": {
		"produces": ["wool cloth", "salted meat", "leather", "pottery", "tools"],
		"wants": ["iron", "wine", "spices", "horses", "salt"],
	},
	"fort": {
		"produces": ["horse tack", "charcoal", "hides"],
		"wants": ["grain", "salt", "wine", "cloth", "cheese"],
	},
	"castle": {
		"produces": ["horses", "charcoal", "stone"],
		"wants": ["wine", "silk", "spices", "grain", "salt"],
	},
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


## Fill a settlement's detail in place. Idempotent: a settlement that already has buildings keeps
## them, so this can be called on every map entry (fresh campaigns and old saves alike).
static func fill(settlement: Settlement, campaign_seed: int) -> void:
	if settlement == null or not settlement.buildings.is_empty():
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = campaign_seed + hash(settlement.id)
	var kind := settlement.type
	settlement.buildings = _pick_buildings(kind, rng)
	settlement.produces = _pick_goods(kind, "produces", rng)
	settlement.wants = _pick_goods(kind, "wants", rng)
	settlement.families = _families(settlement, rng)
	settlement.wealth = _wealth(settlement.population, rng)
	settlement.garrison = _garrison(kind, settlement.population, rng)


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
		var index := rng.randi_range(0, bag.size() - 1)
		var entry: Array = bag[index] as Array
		picked.append({"name": str(entry[0]), "note": str(entry[1])})
		bag.remove_at(index)
	return picked


static func _pick_goods(kind: String, side: String, rng: RandomNumberGenerator) -> Array[String]:
	var table: Dictionary = GOODS_BY_KIND.get(kind, GOODS_BY_KIND["village"]) as Dictionary
	var pool: Array = (table[side] as Array).duplicate()
	var count := clampi(rng.randi_range(2, 3), 2, pool.size())
	# Typed, because Settlement.produces is: an untyped Array assigned to an Array[String] is a
	# runtime error, and the error aborts the rest of fill() with it.
	var picked: Array[String] = []
	for i in count:
		var index := rng.randi_range(0, pool.size() - 1)
		picked.append(str(pool[index]))
		pool.remove_at(index)
	return picked


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
