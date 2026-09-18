class_name WorldChunks
extends RefCounted
## The campaign world as data: chunks generated from periodic noise.
##
## This is the layer under the map. Nothing here draws, and nothing here knows about the camera: a
## chunk is a small block of ground described by numbers, generated on demand from the world seed,
## and identical every time it is asked for. The picture is a later layer's problem, and the
## simulation's only interface to the world is [method sample].
##
## [b]Periodic on purpose.[/b] The owner's world wraps - walk far enough one way and you come back to
## where you started - and a wrapping world has a requirement a big one does not: every field must
## meet its own beginning exactly. A noise sampled on an infinite lattice meets its own beginning with
## a visible seam. So the lattice here is not infinite: it is [constant WORLD_CELLS] wide, and every
## sample wraps its lattice coordinates into that period. The wrap is exact at every octave, which is
## why the seam cannot exist rather than being merely hard to find.
##
## [b]Cost is per chunk crossed, not per world size.[/b] Generating a chunk is a fixed amount of
## arithmetic - [constant CELLS_PER_CHUNK] cells of a few noise samples - and chunks are cached with a
## least-recently-used cap, so the memory a session holds is bounded by what it has looked at lately,
## not by how much world exists. Leaving ground frees a chunk, which is the same arithmetic in
## reverse.

## The world, in world units across. Chunks tile it exactly: 4096 / 64 = 64.
const WORLD_SIZE := 4096.0
## One chunk, in world units. Small enough that a chunk is a couple of milliseconds of work, large
## enough that a rider crosses one in well under a minute.
const CHUNK_SIZE := 64.0
## The campaign world's cell, in world units. Eight, not the battlefield's four: at map scale the
## ground does not need half of that, and the field is the expensive part - a first measurement put a
## chunk at 8.5 ms with 4-unit cells, four times the streaming budget. A battlefield is a *window*,
## and the window re-samples at whatever resolution the fight needs; the world it is cut from can be
## coarser than the fight.
const CELL_SIZE := 8.0
## Cells per chunk, per axis: 64 / 8.
const CELLS_PER_CHUNK := 8
## The world in cells, and the period every noise octave wraps at. Must stay an integer: the wrap
## works by folding lattice coordinates into this period at every octave.
const WORLD_CELLS := 512
## How many generated chunks are kept. Enough for the screen and a margin; the rest are rebuilt, which
## is cheap and always gives the same answer. A variable rather than a constant so a test can prove the
## eviction path without building six hundred chunks to reach it.
var cache_limit := 512

var seed_value: int = 0

var _cache: Dictionary = {}
var _order: Array[Vector2i] = []
var _generated: int = 0
var _generation_usec: int = 0


static func build(p_seed: int) -> WorldChunks:
	var world := WorldChunks.new()
	world.seed_value = p_seed
	return world


## ---------- geometry -------------------------------------------------------

## Which chunk a world position falls in. Wraps: the world has no outside.
static func chunk_of(position: Vector2) -> Vector2i:
	return Vector2i(
		posmod(int(floorf(position.x / CHUNK_SIZE)), int(WORLD_SIZE / CHUNK_SIZE)),
		posmod(int(floorf(position.y / CHUNK_SIZE)), int(WORLD_SIZE / CHUNK_SIZE))
	)


## Where a chunk starts, in world units.
static func chunk_origin(chunk: Vector2i) -> Vector2:
	return Vector2(float(chunk.x), float(chunk.y)) * CHUNK_SIZE


## A world position folded into the world. Anything outside comes back as the place it is the same
## as, because the world is a torus and there is no elsewhere.
##
## Named fold rather than wrap on purpose: wrap() is a GDScript built-in, and a method with that name
## silently resolves to it instead - which cost a compile pass, since the built-in takes three
## arguments and returns a Variant.
static func fold(position: Vector2) -> Vector2:
	return Vector2(
		fposmod(position.x, WORLD_SIZE),
		fposmod(position.y, WORLD_SIZE)
	)


## ---------- sampling -------------------------------------------------------

## Everything the world knows about a place, in one call: the three look weights that decide what the
## ground is, and a height. This is the interface the map draws from and the simulation will read
## from, so that a place cannot look like one thing and behave like another.
func sample(position: Vector2) -> Dictionary:
	var p := fold(position)
	var x := p.x / CELL_SIZE
	var y := p.y / CELL_SIZE
	# The borders wander, as they do on the map: each field is sampled from a point nudged sideways
	# by a slower noise, which turns a soft straight edge into a coast.
	var wander := (_fbm(x, y, 11, 2, 5.4) - 0.5) * 0.22
	var moisture := _fbm(x + wander * 8.0, y, 1, 4, 3.0)
	var wear := _fbm(x + wander * 8.0, y, 17, 3, 4.6)
	var region := _fbm(x, y, 29, 2, 1.1)
	var height := _fbm(x, y, 23, 3, 1.7)
	return {
		"lush": moisture * region,
		"dry": (1.0 - moisture) * region,
		"worn": wear * 0.85,
		"height": height,
		"moisture": moisture,
		"wear": wear,
		"region": region,
	}


func height_at(position: Vector2) -> float:
	return float(sample(position).get("height", 0.5))


## ---------- chunks ---------------------------------------------------------

## Generate a chunk if it is not already held. This is the unit of streaming work: the caller decides
## when to spend it, this decides nothing about timing.
func ensure_chunk(chunk: Vector2i) -> void:
	if _cache.has(chunk):
		return
	var started := Time.get_ticks_usec()
	var data := PackedFloat32Array()
	data.resize(CELLS_PER_CHUNK * CELLS_PER_CHUNK * 3)
	var origin := chunk_origin(chunk)
	for cy in CELLS_PER_CHUNK:
		for cx in CELLS_PER_CHUNK:
			var point := origin + Vector2(float(cx), float(cy)) * CELL_SIZE
			var s := sample(point)
			var index := (cy * CELLS_PER_CHUNK + cx) * 3
			data[index + 0] = float(s["lush"]) - float(s["dry"])
			data[index + 1] = float(s["worn"])
			data[index + 2] = float(s["height"])
	_cache[chunk] = data
	_order.append(chunk)
	while _order.size() > cache_limit:
		var oldest: Vector2i = _order.pop_front()
		_cache.erase(oldest)
	_generated += 1
	_generation_usec += Time.get_ticks_usec() - started


func has_chunk(chunk: Vector2i) -> bool:
	return _cache.has(chunk)


func cached_chunks() -> int:
	return _cache.size()


## How much work has been done across this session, and at what average cost a chunk. The number the
## streaming layer budgets against.
func stats() -> Dictionary:
	return {
		"generated": _generated,
		"cached": _cache.size(),
		"average_ms": (float(_generation_usec) / 1000.0) / maxf(1.0, float(_generated)),
		"total_ms": float(_generation_usec) / 1000.0,
	}


## ---------- noise ----------------------------------------------------------

## Fractal value noise, with its lattice wrapped to the world's period at every octave - so the field
## is continuous across the wrap and a sample at x = WORLD_SIZE is the sample at x = 0, exactly.
func _fbm(x: float, y: float, salt: int, octaves: int, frequency: float) -> float:
	var total := 0.0
	var weight_total := 0.0
	var amplitude := 1.0
	var f := frequency
	for octave in octaves:
		total += _value_noise(x * f, y * f, salt + octave, f) * amplitude
		weight_total += amplitude
		amplitude *= 0.5
		f *= 2.0
	return total / maxf(0.0001, weight_total)


func _value_noise(x: float, y: float, salt: int, frequency: float) -> float:
	var x0 := int(floorf(x))
	var y0 := int(floorf(y))
	var fx := x - floorf(x)
	var fy := y - floorf(y)
	# Smoothstep, so the lattice does not show as diamonds.
	var sx := fx * fx * (3.0 - 2.0 * fx)
	var sy := fy * fy * (3.0 - 2.0 * fy)
	# The lattice wraps here, and only here: the period in lattice units is the world's width in
	# cells times this octave's frequency, which is an integer because every frequency is a whole
	# number. That is what makes the seam impossible rather than unlikely.
	var period := maxi(1, int(round(float(WORLD_CELLS) * frequency)))
	var a := _hash01(posmod(x0, period), posmod(y0, period), salt)
	var b := _hash01(posmod(x0 + 1, period), posmod(y0, period), salt)
	var c := _hash01(posmod(x0, period), posmod(y0 + 1, period), salt)
	var d := _hash01(posmod(x0 + 1, period), posmod(y0 + 1, period), salt)
	return lerpf(lerpf(a, b, sx), lerpf(c, d, sx), sy)


## A number in [0, 1) from three integers, the same on every machine and in any order.
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
