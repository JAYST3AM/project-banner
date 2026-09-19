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
## v4: must-haves gained their purpose's landmarks (market squares, merchant's houses, a castle's
## keep) and attachments gained the by-category rolls, so the life/detail pieces reach walls.
const DETAILS_VERSION := 4

## What each kind of place wants, before the buildings take their cut. Drawn WIDE on purpose: every
## good a building can make is named by at least one kind's basket, or it could never be sold onward
## - that rule is what the first trade pass got wrong, and a suite now enforces it (any good nobody
## wants is a good that strands a caravan). Everything a town can make itself is still subtracted
## below, so a basket is a menu, not a promise.
const WANTS_BY_KIND := {
	"village": ["iron", "salt", "cloth", "tools", "pottery", "ale", "fish", "horses", "weapons"],
	"town": ["iron", "wine", "spices", "silk", "horses", "salt", "wool", "hides", "firewood",
		"charcoal", "wool cloth", "armour", "weapons", "turnips", "fish", "cheese", "grain", "ale",
		"salted meat", "horse tack"],
	"fort": ["grain", "salt", "ale", "leather", "iron", "horses", "weapons", "armour",
		"salted meat", "salted fish", "firewood", "coal", "pottery", "horse tack", "cheese",
		"turnips"],
	"castle": ["wine", "silk", "spices", "grain", "salt", "cheese", "jewellery", "horses",
		"wool cloth", "salted meat", "salted fish", "charcoal", "coal", "stone", "armour",
		"weapons", "turnips", "fish", "ale", "firewood"],
}

## The wants every place of a kind has if it cannot make them itself: the old staples are what kept
## half the map's trade alive, and they are still true. Salt, above all - the one thing a village
## with no salt pans cannot do without.
const STAPLE_WANTS := {
	"village": ["salt", "iron", "tools"],
	"town": ["salt", "wool", "hides"],
	"fort": ["salt", "grain", "leather"],
	"castle": ["salt", "wine", "silk"],
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
	var picked: Array[String] = []
	# The staples first: every place wants these unless it makes them.
	for good_any in (STAPLE_WANTS.get(kind, STAPLE_WANTS["village"]) as Array):
		var staple := str(good_any)
		if not enabled.has(staple) and not picked.has(staple):
			picked.append(staple)
	# Then one or two things off the wide basket, so two towns of a kind do not want the same list.
	var pool: Array[String] = []
	for good_any in (WANTS_BY_KIND.get(kind, WANTS_BY_KIND["village"]) as Array):
		var good := str(good_any)
		if not enabled.has(good) and not picked.has(good):
			pool.append(good)
	var count := clampi(rng.randi_range(1, 2), 0, pool.size())
	for i in count:
		var index := rng.randi_range(0, pool.size() - 1)
		picked.append(pool[index])
		pool.remove_at(index)
	return picked


## The coverage pass: after a whole world's details are filled, two promises must hold, or the road
## dead-ends (which is exactly what the first live trade session showed: six caravans, one delivery
## each, then idle forever).
## [br]1. every good some building can make must have at least one town that wants it;
## [br]2. every town must have a buyer for something it sells, within reach of its own roads.
## Mutates wants in place; idempotent; one pass over the world. [param roads] is the campaign's link
## list (same shape as [member CampaignState.roads]); without it promise 2 is skipped, because
## "within reach" is a question only the roads can answer.
static func repair_world_wants(settlements: Dictionary, roads: Array = []) -> int:
	var buyers := {}
	var neighbours := {}
	for raw in roads:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var link := raw as Dictionary
		if str(link.get("kind", "road")) == "none":
			continue
		var a := str(link.get("a", ""))
		var b := str(link.get("b", ""))
		if a.is_empty() or b.is_empty():
			continue
		(neighbours.get_or_add(a, []) as Array).append(b)
		(neighbours.get_or_add(b, []) as Array).append(a)
	for key in settlements.keys():
		var town := settlements[key] as Settlement
		if town == null:
			continue
		for good in town.wants:
			buyers[good] = int(buyers.get(good, 0)) + 1
	var fixed := 0
	# 1. A good nobody wants is a good that strands a caravan; give it a buyer whose kind deals in it.
	for key in settlements.keys():
		var producer := settlements[key] as Settlement
		if producer == null:
			continue
		for good in producer.produces:
			if int(buyers.get(good, 0)) > 0:
				continue
			var host := _find_buyer_for(good, settlements)
			if host == null:
				continue
			host.wants.append(good)
			buyers[good] = 1
			fixed += 1
			DebugLogger.debug("trade: %s wants %s (no other town did - coverage pass)" % [
				host.name, good], "Trade")
	# 2. A town nobody buys from is a town no caravan can leave; give its goods a nearby buyer.
	if neighbours.is_empty():
		return fixed
	for key in settlements.keys():
		var town := settlements[key] as Settlement
		if town == null or town.produces.is_empty():
			continue
		var in_reach := _towns_in_reach(town, settlements, neighbours)
		if in_reach.is_empty():
			continue
		var served := false
		for other in in_reach:
			for good in town.produces:
				if other.wants.has(good):
					served = true
					break
			if served:
				break
		if served:
			continue
		for other in in_reach:
			var paired := false
			for good in town.produces:
				if other.produces.has(good) or other.wants.has(good):
					continue
				if not (WANTS_BY_KIND.get(other.type, []) as Array).has(good):
					continue
				other.wants.append(good)
				fixed += 1
				paired = true
				DebugLogger.debug("trade: %s wants %s (nearest town that deals in it - coverage pass)" % [
					other.name, good], "Trade")
				break
			if paired:
				break
	return fixed


## The towns a caravan from [param town] could actually reach: link-connected, and within the trade
## window's straight-line reach (the same 1500 u [method TradeService.best_routes] prices against).
## Nearest first.
static func _towns_in_reach(town: Settlement, settlements: Dictionary, neighbours: Dictionary,
		max_units: float = 1500.0) -> Array[Settlement]:
	var found: Array[Settlement] = []
	var seen := {town.id: true}
	var queue: Array[String] = [town.id]
	while not queue.is_empty():
		var here: String = str(queue.pop_front())
		for next_any in (neighbours.get(here, []) as Array):
			var next := str(next_any)
			if seen.has(next):
				continue
			seen[next] = true
			var other := settlements.get(next, null) as Settlement
			if other == null:
				continue
			if town.position.distance_to(other.position) <= max_units:
				found.append(other)
			queue.append(next)
	found.sort_custom(func(a: Settlement, b: Settlement) -> bool:
		return town.position.distance_to(a.position) < town.position.distance_to(b.position))
	return found


## The town that should start wanting a stranded good: one that cannot make it, whose kind's basket
## already names it, with the shortest wants list (so one town does not collect every gap).
static func _find_buyer_for(good: String, settlements: Dictionary) -> Settlement:
	var best: Settlement = null
	for key in settlements.keys():
		var town := settlements[key] as Settlement
		if town == null or town.produces.has(good) or town.wants.has(good):
			continue
		if not (WANTS_BY_KIND.get(town.type, []) as Array).has(good):
			continue
		if best == null or town.wants.size() < best.wants.size():
			best = town
	return best


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
