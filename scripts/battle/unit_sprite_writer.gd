class_name UnitSpriteWriter
extends RefCounted

## The per-soldier sprite step, fused into one call, shared by both battle renderers.
##
## [b]Why it exists.[/b] The canvas battle's [SoldierField] and the compute battlefield both need
## the same thing once a soldier a tick: choose his animation and frame from what changed since
## the last pack, work out where his quad goes, and write the instance the shader draws. As five
## separate calls a soldier (plan, frame, origin, custom, write) that measured 1.95 us a soldier
## in the pack micro-benchmark (scenes/dev/sprite_pack_bench.gd, 2,000 soldiers x 60 reps) against
## 0.87 for one fused call - GDScript's call overhead was most of the cost of the whole step.
## Inlining everything by hand buys almost nothing more (0.82), so this is one call with the maths
## written out inside it, and it is the same code for both renderers rather than two copies.
##
## [b]The maths is inlined, but not invented.[/b] [method UnitArt.plan], [method UnitArt.frame],
## [method UnitArt.origin] and [method UnitArt.custom_from] are the specification; this class is
## the fused implementation of them, and tests/test_unit_sprites.gd pins the two together against
## staged soldier states, so the hot path cannot drift from the pure functions.
##
## [b]Only what changed is written.[/b] An instance's size and tint are constant for a soldier, so
## they go in once, when he is first written; the origin goes in when his picture has moved more
## than [constant FLICKER_EPSILON] since the last write, and the frame rectangle when his chosen
## frame has changed. A rank standing still costs a compare and nothing else. The offset is
## measured from the last [i]written[/i] picture, so a slow drift accumulates until it is written
## rather than being lost.
##
## [b]Two indices.[/b] A soldier has a [i]slot[/i] - where his instance goes in the renderer's
## buffer - and a [i]state[/i] - who he is, which is what the animation memory is keyed by. The
## compute field's soldier i is both; the canvas battle's buffer is packed in draw order, so its
## slots are not its unit ids, and a slot can hold a different man between packs. The writer
## notices that ([member _slot_state]) and writes the new man out in full rather than trusting
## another man's writes.
##
## The writer owns the per-soldier state it needs to know what changed; the renderer owns the
## evidence - whether he moved, how long ago he was hurt or struck, when he fell, which way he
## faces - because the two renderers read that evidence from different places (the compute
## field's readback against the units' own fields).

## How far a soldier's picture has to move before his quad origin is rewritten, in world units
## squared. 0.05 units is a third of a pixel at the atlas's 0.16 units a pixel, and the
## accumulation rule above keeps the error bounded by it.
const FLICKER_EPSILON := 0.0025

const DEFAULT_FALLEN_DARKEN := 0.55

var _stride := 0
var _offsets := PackedInt32Array()
var _foot_lift := 0.0
var _fallen_darken := DEFAULT_FALLEN_DARKEN

## Per side, index 0 the player's: shared with what [method UnitArt.renderer_data] returns.
var _side_common: Array = []
var _side_ticks: Array = []
var _side_frames: Array = []
var _side_uv: Array = []
var _side_uv_stride := PackedInt32Array()
var _tint := PackedColorArray()

## Per soldier state: where his picture was when his origin was last written, and which frame
## rectangle is in the buffer. -1 means he has never been written, which is what puts his
## constant size, tint and origin in on the first pack he appears in.
var _written_picture := PackedVector2Array()
var _written_frame := PackedInt32Array()

## Which soldier's state each slot's instance currently holds, so a re-packed slot whose new man
## is not the old one is written whole.
var _slot_state := PackedInt32Array()


## Ready the writer for a battle: the per-side tables an atlas and a battle rate produce, the
## buffer layout the renderer measured, and the two placements that belong to the look rather than
## the maths. False means the art or the layout is not one this writer can draw, and the renderer
## should keep drawing whatever it drew instead.
func setup(art: UnitArt, keys: Array, rate: float, offsets: PackedInt32Array, stride: int,
		foot_lift: float, fallen_darken: float = DEFAULT_FALLEN_DARKEN) -> bool:
	if art == null or offsets.size() != 6 or stride <= 0:
		return false
	_side_common = []
	_side_ticks = []
	_side_frames = []
	_side_uv = []
	_side_uv_stride = PackedInt32Array()
	for side in keys.size():
		var key := str(keys[side])
		if not art.has_character(key):
			return false
		var data: Dictionary = art.renderer_data(key, rate)
		_side_ticks.append(data["ticks"])
		_side_frames.append(data["frames"])
		_side_uv.append(data["uv"])
		_side_common.append(data["common"])
		_side_uv_stride.append(int(data["uv_stride"]))
	_tint.resize(keys.size())
	for side in keys.size():
		_tint[side] = UnitArt.side_tint(side == 0)
	_offsets = offsets
	_stride = stride
	_foot_lift = foot_lift
	_fallen_darken = fallen_darken
	return true


## Room for [param count] soldiers, every one of them never written.
func reserve(count: int) -> void:
	_written_picture.resize(count)
	_written_picture.fill(Vector2(-1.0e9, -1.0e9))
	_written_frame.resize(count)
	_written_frame.fill(-1)
	_slot_state.resize(count)
	_slot_state.fill(-1)


## How many soldiers the writer has state for. A renderer whose army can grow checks this before
## a pack and reserves again, rather than silently drawing nothing for the new men.
func capacity() -> int:
	return _written_frame.size()


## How tall a soldier stands, in world units - the idle pose's height, which is what a health bar
## hangs off. (The tallest frame is taller: a raised sword. A bar placed off that floats a gap
## above the head between swings.)
func sprite_head() -> float:
	if _side_common.is_empty():
		return 0.0
	var common: PackedFloat32Array = _side_common[0]
	return common[7] if common.size() >= 8 else cell_height(common)


## The cell height out of one side's common block. Split out so the arithmetic is nameable.
static func cell_height(common: PackedFloat32Array) -> float:
	return common[1] * common[4] if common.size() >= 5 else 0.0


func ready() -> bool:
	return _stride > 0 and _offsets.size() == 6 and _side_common.size() > 0


## One soldier's instance, written into [param buffer] at [param slot] (his instance index there).
## [param state] is who he is - the key the animation memory is held under. [param picture] is
## where he is being drawn this pack (the interpolated position), which is what the quad is placed
## from; the ages are in whole ticks, [constant UnitArt.NEVER] meaning it never happened.
func write(buffer: PackedFloat32Array, slot: int, state: int, picture: Vector2, side: int,
		alive: bool, moved: bool, hurt_age: int, strike_age: int, death_age: int, flip: bool,
		tick: int) -> void:
	if side < 0 or side >= _side_common.size():
		return
	if state < 0 or state >= _written_frame.size() or slot < 0:
		return
	var common: PackedFloat32Array = _side_common[side]
	# --- the plan, inlined from UnitArt.plan (the priority order is the whole of it) ------------
	var anim := UnitArt.IDLE
	if not alive:
		anim = UnitArt.DEATH
	elif hurt_age >= 0 and hurt_age < int(common[5]):
		anim = UnitArt.HURT
	elif strike_age >= 0 and strike_age < int(common[6]):
		anim = UnitArt.ATTACK
	elif moved:
		anim = UnitArt.WALK
	# The phase that desynchronises a rank belongs to the loops; a blow, a wound and a death start
	# at their first frame because the soldier just lived them.
	var into := tick + state * UnitArt.PHASE_STRIDE
	if anim == UnitArt.DEATH:
		into = maxi(0, death_age)
	elif anim == UnitArt.HURT:
		into = maxi(0, hurt_age)
	elif anim == UnitArt.ATTACK:
		into = maxi(0, strike_age)
	# --- the frame, inlined from UnitArt.frame: the loops wrap, a corpse holds its last pose ----
	var ticks: PackedInt32Array = _side_ticks[side]
	var counts: PackedInt32Array = _side_frames[side]
	var per := ticks[anim]
	if per < 1:
		per = 1
	var count := counts[anim]
	if count < 1:
		count = 1
	var step := int(into / per)
	var frame := 0
	if anim == UnitArt.DEATH:
		frame = clampi(step, 0, count - 1)
	else:
		frame = posmod(step, count)
	var base := slot * _stride
	# Every one of these is an offset in its own right, read from the flat array: the transform's
	# scale and origin are measured as separate slots (the x scale, the y scale, the origin's x,
	# the origin's y), never as pairs, because the engine's layout is not one.
	var off_size_x := _offsets[0]
	var off_size_y := _offsets[1]
	var off_origin_x := _offsets[2]
	var off_origin_y := _offsets[3]
	var off_colour := _offsets[4]
	var off_custom := _offsets[5]
	var key := anim * _side_uv_stride[side] + frame
	var fresh := _written_frame[state] < 0 or _slot_state[slot] != state
	_slot_state[slot] = state
	if fresh:
		# Size and tint are what do not change for a soldier: written once, with the origin
		# (which the sentinel picture forces in below) and his first frame.
		var units := common[4]
		buffer[base + off_size_x] = common[0] * units
		buffer[base + off_size_y] = common[1] * units
	if fresh or _written_frame[state] != key:
		_written_frame[state] = key
		var rect: Vector4 = _side_uv[side][key]
		if flip:
			buffer[base + off_custom] = rect.x + rect.z
			buffer[base + off_custom + 2] = -rect.z
		else:
			buffer[base + off_custom] = rect.x
			buffer[base + off_custom + 2] = rect.z
		buffer[base + off_custom + 1] = rect.y
		buffer[base + off_custom + 3] = rect.w
		if fresh or not alive:
			# A corpse is drawn darkened; this lands on the pack he falls in, and again on the
			# frames of the fall, which is rare enough to be free.
			var colour := _tint[side]
			if not alive:
				colour = colour.darkened(_fallen_darken)
			buffer[base + off_colour] = colour.r
			buffer[base + off_colour + 1] = colour.g
			buffer[base + off_colour + 2] = colour.b
			buffer[base + off_colour + 3] = colour.a
	var delta := picture - _written_picture[state]
	if fresh or delta.x * delta.x + delta.y * delta.y > FLICKER_EPSILON:
		_written_picture[state] = picture
		# The origin, inlined from UnitArt.origin: the frame's anchor - the body's centre column
		# on the cell's bottom edge - sits on the foot, and the quad is centred on its own origin.
		var cell_w := common[0]
		var cell_h := common[1]
		var units := common[4]
		var foot_y := picture.y + _foot_lift
		buffer[base + off_origin_x] = picture.x + cell_w * units * 0.5 - common[2] * units
		buffer[base + off_origin_y] = foot_y - cell_h * units * 0.5
