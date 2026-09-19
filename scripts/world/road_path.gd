class_name RoadPath

## The shape of a road, in one place, because two things need it and they must agree: the map draws
## roads with it, and the party walks them with it. Until now the curve lived inside the map view, so
## the party marched in a straight line while the road it was supposedly using wandered -
## the owner: "I dont see the player following the road."
##
## Deterministic: the bend is a hash of the two endpoints alone, so the same campaign always bends the
## same road the same way, a save reloads to the roads it had, and nothing about it is stored.

const SEGMENTS := 48
## Fallbacks for the terrain shaping; callers pass their config's own figures.
const WATER_HEIGHT := 0.335
## How wide a water crossing may be and still count as a bridgeable river rather than a lake to
## bend around.
const BRIDGE_MAX_SPAN := 64.0


## Which way, and how hard, a road bends - a property of the road, not of the direction it is read in.
##
## The endpoints are put in a canonical order first, and that is the whole fix for roads that "don't
## match up": bend_of(a, b) and bend_of(b, a) used to differ, so the map drawing a road from A to B and
## the party walking it from B to A produced two curves mirrored about the straight line between them.
## The party was following a different road from the one on screen, and the only place that shows is a
## route - which is why the owner saw it on roads and nowhere else.
static func bend_of(a: Vector2, b: Vector2) -> float:
	var first := a
	var second := b
	if (a.x + a.y * 1.7) > (b.x + b.y * 1.7):
		first = b
		second = a
	var raw := sin(first.x * 12.9898 + first.y * 78.233 + second.x * 37.719 + second.y * 94.673) * 43758.5453
	return (raw - floorf(raw)) * 2.0 - 1.0


## The road's own line from a to b. Without a terrain this is the historic bend and nothing else;
## with one, water decides: a road never simply runs over it. The canonical bend is tried first, then
## its mirror and wider bows - the first shape that is dry, or crosses only water a bridge spans, is
## the road. A lake the line cannot dodge keeps the least-wet shape, which is the fewest units of
## water possible. The owner's first road rule: "don't let them run over water, but we could do
## bridges over water."
static func between(a: Vector2, b: Vector2, terrain: Object = null, water_height := WATER_HEIGHT, bridge_max_span := BRIDGE_MAX_SPAN) -> PackedVector2Array:
	var span := a.distance_to(b)
	if span < 24.0:
		return PackedVector2Array([a, b])
	var bend := bend_of(a, b)
	if terrain == null:
		return shape(a, b, bend)
	# Wider bows join the list as well as their mirror: a long link across a broad lake needs reach
	# the canonical bend does not have (found live: a 396-unit causeway where no bow could dodge).
	var choices: Array[float] = [bend, -bend, bend * 1.6, -bend * 1.6, bend * 2.2, -bend * 2.2, 0.0]
	var best := PackedVector2Array()
	var best_wet := INF
	for candidate in choices:
		var path := shape(a, b, candidate)
		var wet := _longest_water_run(path, terrain, water_height)
		if wet <= bridge_max_span:
			return path
		if wet < best_wet:
			best_wet = wet
			best = path
	return best


## The bare shape, for a given bend: every term is multiplied by a window that is zero at both ends,
## so the offset is exactly zero at each settlement - the road meets its towns by construction, not
## by luck.
static func shape(a: Vector2, b: Vector2, bend: float) -> PackedVector2Array:
	var span := a.distance_to(b)
	var side := Vector2(b.y - a.y, a.x - b.x).normalized()
	var path := PackedVector2Array()
	for i in SEGMENTS + 1:
		var t := float(i) / float(SEGMENTS)
		var window := sin(t * PI)
		var offset := window * bend * span * 0.15
		offset += sin(t * PI * 3.0 + bend * 5.0) * span * 0.032 * window
		offset += sin(t * PI * 5.0 + bend * 11.0) * span * 0.010 * window
		path.append(a.lerp(b, t) + side * offset)
	return path


## The stretches of a shaped curve that lie over water: [start, end] index pairs into the path -
## where the map draws a bridge and the walk crosses by one. The bank point is included at each end,
## so the bridge visibly rests on land. Empty when the road never touches water.
static func water_spans(path: PackedVector2Array, terrain: Object, water_height := WATER_HEIGHT) -> Array:
	var spans: Array = []
	if terrain == null or path.size() < 2:
		return spans
	var start := -1
	for i in range(1, path.size()):
		if _is_water(terrain, path[i], water_height):
			if start < 0:
				start = i - 1
		elif start >= 0:
			spans.append(Vector2i(start, i))
			start = -1
	if start >= 0:
		spans.append(Vector2i(start, path.size() - 1))
	return spans


## The longest unbroken stretch of water under a curve, in units - the number the shaping brings
## under the bridge limit.
static func _longest_water_run(path: PackedVector2Array, terrain: Object, water_height: float) -> float:
	var longest := 0.0
	var run := 0.0
	for i in range(1, path.size()):
		if _is_water(terrain, path[i], water_height):
			run += path[i - 1].distance_to(path[i])
			longest = maxf(longest, run)
		else:
			run = 0.0
	return longest


static func _is_water(terrain: Object, point: Vector2, water_height: float) -> bool:
	var here: Variant = terrain.call("sample", point)
	if typeof(here) != TYPE_DICTIONARY:
		return false
	return float((here as Dictionary).get("height", 1.0)) < water_height
