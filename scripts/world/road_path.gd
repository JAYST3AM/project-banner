class_name RoadPath

## The shape of a road, in one place, because two things need it and they must agree: the map draws
## roads with it, and the party walks them with it. Until now the curve lived inside the map view, so
## the party marched in a straight line while the road it was supposedly using wandered -
## the owner: "I dont see the player following the road."
##
## Deterministic: the bend is a hash of the two endpoints alone, so the same campaign always bends the
## same road the same way, a save reloads to the roads it had, and nothing about it is stored.

const SEGMENTS := 48


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


static func between(a: Vector2, b: Vector2) -> PackedVector2Array:
	var span := a.distance_to(b)
	var path := PackedVector2Array([a, b])
	if span < 24.0:
		return path
	var side := Vector2(b.y - a.y, a.x - b.x).normalized()
	var bend := bend_of(a, b)
	path = PackedVector2Array()
	for i in SEGMENTS + 1:
		var t := float(i) / float(SEGMENTS)
		# Every term is multiplied by a window that is zero at both ends, so the offset is exactly
		# zero at each settlement: the road meets its towns by construction, not by luck.
		var window := sin(t * PI)
		var offset := window * bend * span * 0.15
		offset += sin(t * PI * 3.0 + bend * 5.0) * span * 0.032 * window
		offset += sin(t * PI * 5.0 + bend * 11.0) * span * 0.010 * window
		path.append(a.lerp(b, t) + side * offset)
	return path
