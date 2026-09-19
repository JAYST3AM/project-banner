class_name BattlefieldDecals
extends RefCounted
## The marks a battle leaves on the ground: blood, footprints, churned mud, trampled grass, scorch
## marks, broken vegetation, wheel tracks, craters.
##
## [b]Lightweight by construction.[/b] A decal is a number, not a node: a fixed-capacity pool of
## packed arrays with no objects, no physics, no per-frame work and no simulation. Nothing here
## decides anything - the battle paints a mark when something happened, and the ground keeps it for a
## while.
##
## [b]Merged, then culled.[/b] A battle paints thousands of marks in the same few square metres, and
## a hundred blood spots a centimetre apart are one stain. A paint that lands on top of its own kind
## is *merged* into the decal already there - stronger, slightly bigger, and no new record - and only
## when the pool is genuinely full does the oldest mark give way. That pair of rules is what keeps a
## long fight from growing a data structure: the pool has a hard ceiling, and the number of records
## in it is a function of the ground, not of the length of the battle.
##
## [b]Deterministic.[/b] Given the same paints in the same order, two runs produce the same decals -
## no wall clock, no frame delta, no engine RNG. The tick a decal was born on is part of its record,
## so ageing is a subtraction.

## What a mark is. The kinds with their own gameplay meaning (trampled ground costing speed, a crater
## being an obstacle) are the ones a later milestone will read; they are here as kinds already so that
## adding that reading does not change the record.
enum Kind {
	BLOOD,
	FOOTPRINT,
	MUD,
	TRAMPLED,
	SCORCH,
	BROKEN,
	TRACK,
	CRATER,
}

const KIND_NAMES := ["blood", "footprint", "mud", "trampled", "scorch", "broken", "track", "crater"]

## How close a new mark of the same kind has to land before it becomes part of the one already there,
## in world units. Blood pools; footprints do not, or a marching army leaves one long smear.
##
## A mark that has reached full strength keeps absorbing: the pool's ceiling is the *ground*, not the
## number of blows, and a stain that stopped merging would start a new record for every further blow -
## which is exactly the pile-up the merge exists to prevent.
const MERGE_RADIUS := {
	Kind.BLOOD: 2.0,
	Kind.FOOTPRINT: 0.6,
	Kind.MUD: 1.6,
	Kind.TRAMPLED: 2.2,
	Kind.SCORCH: 2.4,
	Kind.BROKEN: 1.4,
	Kind.TRACK: 1.2,
	Kind.CRATER: 3.0,
}

## How much stronger a merged mark gets each time something lands on it. Capped, so a hundred hits in
## the same spot read as a stain rather than as a hole in the world.
const MERGE_GAIN := 0.18
const MAX_STRENGTH := 1.0

var capacity: int = 2048
var size: Vector2 = Vector2(100.0, 60.0)
## Cell size of the lookup grid, in world units. Only has to be at least the widest merge radius.
var cell_size: float = 4.0

var _kind: PackedInt32Array = PackedInt32Array()
var _x: PackedFloat32Array = PackedFloat32Array()
var _y: PackedFloat32Array = PackedFloat32Array()
var _rotation: PackedFloat32Array = PackedFloat32Array()
var _strength: PackedFloat32Array = PackedFloat32Array()
var _born_tick: PackedInt32Array = PackedInt32Array()
var _merged: PackedInt32Array = PackedInt32Array()
var _count: int = 0
var _next: int = 0
var _merges: int = 0
var _evictions: int = 0
var _buckets: Dictionary = {}
var _grid_cols: int = 1
var _grid_rows: int = 1


static func create(p_capacity: int = 2048, p_size: Vector2 = Vector2(100.0, 60.0)) -> BattlefieldDecals:
	var decals := BattlefieldDecals.new()
	decals.capacity = maxi(16, p_capacity)
	decals.size = p_size
	decals._allocate()
	return decals


func _allocate() -> void:
	_kind.resize(capacity)
	_x.resize(capacity)
	_y.resize(capacity)
	_rotation.resize(capacity)
	_strength.resize(capacity)
	_born_tick.resize(capacity)
	_merged.resize(capacity)
	_grid_cols = maxi(1, int(ceilf(size.x / cell_size)))
	_grid_rows = maxi(1, int(ceilf(size.y / cell_size)))
	_buckets.clear()


## Paint a mark. Returns the slot it landed in: the one it merged into, or a fresh one.
##
## The order of the questions is the whole design: merge first (cheap, and the common case in a
## melee), then a fresh record, and only when there is no room does anything get thrown away.
func paint(kind: int, position: Vector2, strength: float = 1.0, rotation: float = 0.0, tick: int = 0) -> int:
	var slot := _find_merge(kind, position)
	if slot >= 0:
		_merges += 1
		_merged[slot] += 1
		_strength[slot] = clampf(_strength[slot] + MERGE_GAIN * maxf(0.1, strength), 0.0, MAX_STRENGTH)
		_born_tick[slot] = tick
		return slot
	var index := _next
	if _count < capacity:
		_count += 1
	else:
		_evictions += 1
		_unbucket(index)
	_next = (_next + 1) % capacity
	_kind[index] = kind
	_x[index] = position.x
	_y[index] = position.y
	_rotation[index] = rotation
	_strength[index] = clampf(strength, 0.0, MAX_STRENGTH)
	_born_tick[index] = tick
	_merged[index] = 0
	_bucket(index)
	return index


## The decal of the same kind this paint belongs to, if there is one near enough.
func _find_merge(kind: int, position: Vector2) -> int:
	var radius := float(MERGE_RADIUS.get(kind, 1.0))
	var col := int(floorf(position.x / cell_size))
	var row := int(floorf(position.y / cell_size))
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var key := Vector2i(col + dx, row + dy)
			var bucket: Variant = _buckets.get(key, null)
			if bucket == null:
				continue
			for slot in bucket as Array:
				if _kind[slot] != kind:
					continue
				if Vector2(_x[slot], _y[slot]).distance_squared_to(position) <= radius * radius:
					return slot
	return -1


func _bucket(index: int) -> void:
	var key := Vector2i(int(floorf(_x[index] / cell_size)), int(floorf(_y[index] / cell_size)))
	if not _buckets.has(key):
		_buckets[key] = []
	(_buckets[key] as Array).append(index)


func _unbucket(index: int) -> void:
	var key := Vector2i(int(floorf(_x[index] / cell_size)), int(floorf(_y[index] / cell_size)))
	var bucket: Variant = _buckets.get(key, null)
	if bucket == null:
		return
	(bucket as Array).erase(index)


## ---------- reading -------------------------------------------------------

func count() -> int:
	return _count


func is_empty() -> bool:
	return _count == 0


func kind_at(index: int) -> int:
	return _kind[index] if index >= 0 and index < _count else -1


func position_at(index: int) -> Vector2:
	if index < 0 or index >= _count:
		return Vector2.ZERO
	return Vector2(_x[index], _y[index])


func rotation_at(index: int) -> float:
	return _rotation[index] if index >= 0 and index < _count else 0.0


func strength_at(index: int) -> float:
	return _strength[index] if index >= 0 and index < _count else 0.0


func born_tick_at(index: int) -> int:
	return _born_tick[index] if index >= 0 and index < _count else 0


func merges_at(index: int) -> int:
	return _merged[index] if index >= 0 and index < _count else 0


func kind_name(kind: int) -> String:
	return str(KIND_NAMES[clampi(kind, 0, KIND_NAMES.size() - 1)])


func merge_count() -> int:
	return _merges


func eviction_count() -> int:
	return _evictions


func counts_by_kind() -> Dictionary:
	var counts := {}
	for index in _count:
		var name := kind_name(_kind[index])
		counts[name] = int(counts.get(name, 0)) + 1
	return counts


## How many records the pool would hold if nothing merged - the number that says whether the ceiling
## is doing anything. A long fight with no merging would have filled the pool many times over.
func paints_attempted() -> int:
	return _merges + _evictions + _count


## A fingerprint of every mark: kind, position, strength. Two battles that painted the same marks in
## the same places stamped the same ground.
func signature() -> String:
	var accumulator := 2166136261
	for index in _count:
		accumulator = BattlefieldTerrain._mix(accumulator, _kind[index])
		accumulator = BattlefieldTerrain._mix(accumulator, int(round(_x[index] * 32.0)))
		accumulator = BattlefieldTerrain._mix(accumulator, int(round(_y[index] * 32.0)))
		accumulator = BattlefieldTerrain._mix(accumulator, int(round(_strength[index] * 64.0)))
	return "%08x" % (accumulator & 0xffffffff)


func summary() -> String:
	return "decals: %d of %d slots, %d merged, %d evicted, %s" % [
		_count, capacity, _merges, _evictions, str(counts_by_kind()),
	]


func to_dict() -> Dictionary:
	return {
		"count": _count,
		"capacity": capacity,
		"merged": _merges,
		"evicted": _evictions,
		"kinds": counts_by_kind(),
		"signature": signature(),
	}


## ---------- painting a battle ---------------------------------------------

## The paint a weapon hit leaves: blood, and enough of it that a fight is legible afterwards.
##
## Free functions rather than a policy: what a battle paints is the battle's business, and the
## callers that want to paint something else (tracks behind a wagon, craters under a siege engine)
## call [method paint] themselves.
static func paint_hit(decals: BattlefieldDecals, position: Vector2, tick: int, damage: float = 1.0) -> int:
	if decals == null:
		return -1
	return decals.paint(Kind.BLOOD, position, clampf(0.35 + damage * 0.02, 0.2, 0.9), 0.0, tick)


static func paint_death(decals: BattlefieldDecals, position: Vector2, tick: int) -> int:
	if decals == null:
		return -1
	return decals.paint(Kind.BLOOD, position, 0.9, 0.0, tick)
