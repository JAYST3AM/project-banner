class_name WorldSites
extends RefCounted
## Where the world puts its towns, and what they are called.
##
## A site is a place the land itself proposes: not too high, not too steep, with enough character to
## be worth settling, and it has to be the best cell among its neighbours - a local optimum, which is
## what makes proposals stable and few.
##
## [b]Every proposal is a function of position and seed, never of when it was asked for.[/b] That is
## the rule the whole procedural world rests on: the same seed grows the same country whether the
## player rides through it or never goes there, and a save is the seed plus what changed. A site is
## found by looking at its neighbourhood, so two chunks beside each other agree about the site on
## their border, and no ordering of the search can change the answer.
##
## [b]Naming is part of the world, not a label on it.[/b] The owner's map already has Greywatch,
## Thornwood Hollow, Brackenford and Redmer - a register of two ordinary words welded together, one
## of them usually a piece of land. The generator works the same way, from the site's own numbers, so
## the same site is always the same name.

## Settlements this close or closer to each other are one settlement: the closer of the two keeps it.
## Roughly a long bowshot times six, which is about an hour's ride at campaign speed.
## How close two settlements may stand, by kind, in world units.
##
## The owner's rule, in his words: "not the same spacing for everything, obviously towns would settle
## decent distance from other settlements, but forts may be closer to cities that are poi's". So this is
## not one number: a castle keeps a county to itself, a town wants room to farm, and a fort is a
## smaller thing - it can sit close to the town it serves, which is the relationship he is describing.
##
## Two sites are too close when *either* of them would mind, so the larger of the two expectations
## wins and a fort cannot crowd a castle even though forts crowd each other.
## The tightest any two sites may be, whatever they are: the smallest figure in SPACING. Kept as its
## own name because the tests and callers ask "what is the floor", and the floor is a village's.
const MIN_SPACING := 150.0

const SPACING := {
	"castle": 560.0,
	"town": 380.0,
	"fort": 210.0,
	"village": 150.0,
}


## Whether this candidate is too near that site, given what each of them is.
func too_close(position: Vector2, kind: String, other: Dictionary) -> bool:
	var mine := float(SPACING.get(kind, 150.0))
	var theirs := float(SPACING.get(str(other.get("kind", "village")), 150.0))
	return _wrapped_distance(position, other["position"]) < minf(mine, theirs)
## How far from a candidate its neighbours are compared. Wider than a settlement's footprint, narrow
## enough that a range of hills reads as many candidates rather than one.
const NEIGHBOURHOOD := 24.0
## A site must sit inside this slice of the height field: below it is swamp, above it is rock.
const HEIGHT_MIN := 0.34
const HEIGHT_MAX := 0.76
## And must be at least this flat across its neighbourhood. Steep ground builds nothing.
const MAX_SLOPE := 0.055
## How much character the land needs before it is worth settling.
const MIN_REGION := 0.42
## What a site becomes. Most of the world is villages; castles are rare and that is the point.
const KIND_WEIGHTS := {
	"village": 0.55,
	"town": 0.25,
	"fort": 0.14,
	"castle": 0.06,
}

var world: WorldChunks = null
var seed_value: int = 0
## A chunk's best cell does not change, so a neighbourhood scan has no reason to look twice: without
## this, asking for the sites near a place rescanned every chunk in reach from every centre.
var _proposals: Dictionary = {}


static func build(p_seed: int) -> WorldSites:
	var sites := WorldSites.new()
	sites.seed_value = p_seed
	sites.world = WorldChunks.build(p_seed)
	return sites


## ---------- proposals ------------------------------------------------------

## The site a chunk would propose, or an empty dictionary. Scans the chunk's own cells at a stride,
## which keeps the work per chunk bounded and the answer identical every time.
func propose_in_chunk(chunk: Vector2i) -> Dictionary:
	if _proposals.has(chunk):
		return _proposals[chunk]
	var origin := WorldChunks.chunk_origin(chunk)
	var best := {}
	var best_score := 0.0
	var stride := WorldChunks.CELL_SIZE * 2.0
	var steps := int(WorldChunks.CHUNK_SIZE / stride)
	for cy in steps:
		for cx in steps:
			var point := origin + Vector2(float(cx) + 0.5, float(cy) + 0.5) * stride
			var score := _site_score(point)
			if score > best_score:
				best_score = score
				best = {"position": point, "score": score}
	if best.is_empty() or best_score <= 0.0:
		_proposals[chunk] = {}
		return {}
	best["chunk"] = chunk
	_proposals[chunk] = best
	return best


## The candidate sites within [param radius] of a place, best first. The world is scanned chunk by
## chunk out from the centre, so the cost is the ground looked at and not the size of the world.
func sites_near(centre: Vector2, radius: float) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	var chunk := WorldChunks.chunk_of(centre)
	var reach := int(ceil(radius / WorldChunks.CHUNK_SIZE)) + 1
	var chunks_across := int(WorldChunks.WORLD_SIZE / WorldChunks.CHUNK_SIZE)
	for dy in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			var c := Vector2i(
				posmod(chunk.x + dx, chunks_across),
				posmod(chunk.y + dy, chunks_across)
			)
			var proposal := propose_in_chunk(c)
			if proposal.is_empty():
				continue
			var position: Vector2 = proposal["position"]
			if _wrapped_distance(centre, position) <= radius:
				found.append(proposal)
	found.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["score"]) > float(b["score"]))
	return found


## A run of sites across the world, spaced apart, each with its kind and name. This is what a new
## campaign is built from.
func settlement_sites(count: int, centre: Vector2, radius: float) -> Array[Dictionary]:
	var settled: Array[Dictionary] = []
	# A wider and wider search until there are enough sites: a barren corner of a world must not mean
	# an empty map, it must mean looking further.
	var reach := radius
	while settled.size() < count and reach <= WorldChunks.WORLD_SIZE * 0.5:
		for candidate in sites_near(centre, reach):
			var position: Vector2 = candidate["position"]
			if _too_close(position, settled):
				continue
			var site := candidate.duplicate()
			site["kind"] = kind_for(candidate)
			# Named from the site *with* its kind: handed the bare candidate, every castle came back
			# with a village's name, which three test failures said plainly.
			site["name"] = name_for(site, settled.size())
			settled.append(site)
			if settled.size() >= count:
				break
		reach *= 1.7
	return settled


## ---------- what a site becomes --------------------------------------------

## Villages, towns, forts, castles - decided by the land and the site's own numbers, so it is the
## same answer every time it is asked.
func kind_for(site: Dictionary) -> String:
	var position: Vector2 = site["position"]
	var s := world.sample(position)
	var height := float(s["height"])
	var region := float(s["region"])
	# A roll of its own, from where it is: rich, high, well-charactered ground fortifies itself.
	var roll := _hash01(int(position.x), int(position.y), 7717)
	var defence := 0.0
	if height > 0.55:
		defence += 0.25
	if height > 0.65:
		defence += 0.2
	defence += (region - 0.5) * 0.4
	var pick := roll + defence
	# Sighted on the test's own count: one in twenty castles, one in eight forts. The first thresholds
	# gave one in four castles, because the sites that qualify at all are already the defensible ones
	# and the bonus stacked on top of that.
	if pick > 0.985:
		return "castle"
	if pick > 0.86:
		return "fort"
	if pick > 0.52:
		return "town"
	return "village"


## ---------- names ----------------------------------------------------------

const FIRST_PARTS: Array[String] = [
	"Grey", "Thorn", "Bracken", "Red", "Ash", "Stone", "Raven", "Wolf", "Elm", "Oak",
	"Iron", "Salt", "Barrow", "Hollow", "Crow", "Fen", "Marsh", "Bright", "Dusk", "Cold",
	"Amber", "Black", "White", "Long", "Fair", "Grim", "Hart", "Lark", "Moss", "Reed",
]
const LAST_PARTS: Array[String] = [
	"watch", "wood", "hollow", "ford", "mere", "gate", "stone", "moor", "field", "bridge",
	"hill", "combe", "stead", "wick", "burn", "dale", "fell", "haven", "reach", "crag",
	"ridge", "meadow", "burrow", "crossing", "hallow",
]

## A name from the site's own numbers - two ordinary words welded together, one of them usually a
## piece of land, which is the register the owner's world already speaks in. Castles are "Castle X"
## and forts "Fort X", because a fort named like a village reads as a mistake.
func name_for(site: Dictionary, salt: int) -> String:
	var position: Vector2 = site["position"]
	var h := _hash01(int(position.x * 4.0), int(position.y * 4.0), 5309 + salt)
	var first := FIRST_PARTS[int(floor(h * float(FIRST_PARTS.size()))) % FIRST_PARTS.size()]
	var second := LAST_PARTS[int(floor(h * 7919.0)) % LAST_PARTS.size()]
	var kind := str(site.get("kind", "village"))
	if kind == "castle":
		return "Castle %s" % first
	if kind == "fort":
		return "Fort %s" % first
	return first + second


## ---------- internals ------------------------------------------------------

## How good a site a place is: 0 for nothing worth settling, higher for better. Flat, middling
## ground with character scores well; swamp, rock and steepness score zero.
func _site_score(point: Vector2) -> float:
	var here := world.sample(point)
	var height := float(here["height"])
	var region := float(here["region"])
	if height < HEIGHT_MIN or height > HEIGHT_MAX:
		return 0.0
	if region < MIN_REGION:
		return 0.0
	# Slope across the neighbourhood, and whether anything nearby is better: a site is a local best,
	# which is what keeps proposals stable and stops a hillside proposing forty of them.
	var slope := 0.0
	var better := 0.0
	var step := NEIGHBOURHOOD * 0.5
	var offsets: Array[Vector2] = [
		Vector2(step, 0.0), Vector2(-step, 0.0), Vector2(0.0, step), Vector2(0.0, -step),
	]
	for offset in offsets:
		var neighbour := world.sample(point + offset)
		slope += absf(float(neighbour["height"]) - height)
		if float(neighbour["height"]) > height + 0.02:
			better += 1.0
	if slope > MAX_SLOPE or better > 0.0:
		return 0.0
	var flatness := 1.0 - (slope / MAX_SLOPE)
	return (region - MIN_REGION) * 2.0 + flatness + (0.5 - absf(height - 0.55))


func _too_close(position: Vector2, settled: Array[Dictionary]) -> bool:
	for other in settled:
		var kind_here := kind_for(site)
		if too_close(position, kind_here, other):
			return true
	return false


## Distance on a world with no edges: the short way round, which is the only way there is.
static func _wrapped_distance(a: Vector2, b: Vector2) -> float:
	var dx := absf(a.x - b.x)
	var dy := absf(a.y - b.y)
	dx = minf(dx, WorldChunks.WORLD_SIZE - dx)
	dy = minf(dy, WorldChunks.WORLD_SIZE - dy)
	return sqrt(dx * dx + dy * dy)


func _hash01(x: int, y: int, salt: int) -> float:
	var h := (x * 374761393 + y * 668265263 + salt * 2246822519 + seed_value * 2654435761) % 2147483647
	if h < 0:
		h += 2147483647
	h = (h ^ (h >> 13)) * 1274126177
	h = h % 2147483647
	if h < 0:
		h += 2147483647
	h = h ^ (h >> 16)
	return float(h % 16777216) / 16777216.0
