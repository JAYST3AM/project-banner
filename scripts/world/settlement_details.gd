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
##
## Since D-138 the buildings themselves come from [SettlementBuildings]: the modular catalogue that
## decides what stands where from the town's kind, size, wealth, ground and work - and dresses each
## building with a condition, materials and attachments, which is what a sprite will one day be
## assembled from. This file still owns the trade rule above, the houses, the wealth and the
## garrison.

## Bump when the generation rules change: a save whose detail predates this is regenerated on the
## next map entry, because the old rolls no longer describe the same town.
##
## v3 (D-138): buildings come from the modular catalogue - category, condition, materials and
## attachments - instead of the kind's flat list.
const DETAILS_VERSION := 3

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

	# Wealth first: the building plan reads it for gates, conditions and the pocket, so it cannot be
	# rolled after the town it describes.
	settlement.wealth = _wealth(settlement.population, rng)
	# The town itself, from the modular system (D-138): what the ground and the work make of it.
	var planned := SettlementBuildings.plan(settlement, campaign_seed, settlement.wealth)
	settlement.biome = str(planned.get("biome", ""))
	settlement.buildings = planned.get("buildings", []) as Array
	# Then trade read out of the buildings, so the card can never show a good the town has no
	# building for (D-136).
	var enabled := _enabled_goods(settlement.buildings)
	settlement.produces = _pick_from(enabled, rng)
	settlement.wants = _pick_wants(kind, enabled, rng)
	settlement.families = _families(settlement, rng)
	settlement.garrison = _garrison(kind, settlement.population, rng)
	settlement.details_version = DETAILS_VERSION


## ---------- buildings ----------------------------------------------------

## Every good the chosen buildings can provide, in the order they were picked. Reads the building
## dictionaries the plan produced, so the trade rule follows whatever the catalogue decides.
static func _enabled_goods(buildings: Array) -> Array[String]:
	var goods: Array[String] = []
	for entry in buildings:
		for good_any in ((entry as Dictionary).get("enables", []) as Array):
			var good := str(good_any)
			if not goods.has(good):
				goods.append(good)
	return goods


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
